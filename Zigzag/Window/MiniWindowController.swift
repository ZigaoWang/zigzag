import AppKit
import WebKit

/// Zigzag Mini: one page in a small, quiet window of its own, with no sidebar, for a link from another app or a
/// quick look-up. It wears its space as a browser window does (the same color, the same page card), with only the
/// page's name on top and Open in Zigzag beside it. Its page is a real tab, so history, blocking, autofill and
/// extensions work as they do anywhere; Open in Zigzag moves that same live page into a browser window. It's never
/// saved: quitting lets it go, as Arc did.
final class MiniWindowController: NSWindowController, NSWindowDelegate {
    /// Open ones, oldest first, for placing the next one and for extensions.
    private(set) static var all: [MiniWindowController] = []
    /// The one you're in, if any.
    static var key: MiniWindowController? { all.first { $0.window?.isKeyWindow == true } }

    /// What the feature is called wherever Zigzag names it.
    static var name: String { String(localized: "Zigzag Mini", comment: "The name of Zigzag's small window for one page, without the sidebar (Arc called it Little Arc). Kept in Latin letters, like the app's name.") }

    let tab: Tab
    private let root = MiniRootView()
    private var strip: MiniStripView { root.strip }
    /// Where floating things go over the page: the link under the pointer, a site's question, a toast.
    var overlay: PassthroughView { root.overlay }
    private lazy var linkStatus = LinkStatusController(overlay: overlay)
    /// ⌘L: the browser window's own command bar, over the page's name.
    private lazy var commandBar = CommandBarController(host: self)
    private var tokens: [SignalToken] = []
    private var borderlessToken: NSObjectProtocol?
    /// The page went into a browser window: closing this one must leave it alone.
    private var movedOut = false
    /// Sent once the page has left (into a browser window, or closed with the window), so questions over it go too.
    private let pageGone = Signal<Void>()
    private var isClosing = false
    /// Fading away before it closes or moves into Zigzag: nothing more to do in it.
    private var isLeaving = false

    /// Settings › Zigzag Mini: links from other apps open here instead of in a tab. Off unless you turn it on.
    static var opensExternalLinks: Bool {
        get { UserDefaults.standard.bool(forKey: "OpensExternalLinksInMini") }
        set { UserDefaults.standard.set(newValue, forKey: "OpensExternalLinksInMini") }
    }

    /// Whether a page another app hands over goes to Zigzag Mini: only web links, only with the setting on, and
    /// never before onboarding is done, whose first window is where you start.
    nonisolated static func takes(_ url: URL, settingOn: Bool, needsOnboarding: Bool) -> Bool {
        settingOn && !needsOnboarding && ["http", "https"].contains(url.scheme?.lowercased() ?? "")
    }

    /// Opens one on `url`. `origin`: where on screen it grows from (the quick open bar it came out of); without
    /// one it takes the middle of the screen, a step down from any already there.
    @discardableResult
    static func open(url: URL, isSearch: Bool = false, from origin: NSRect? = nil) -> MiniWindowController {
        let controller = MiniWindowController(url: url, origin: origin)
        controller.tab.isSearchTab = isSearch
        all.append(controller)
        Diagnostics.note("Zigzag Mini opened", site: url.host())
        controller.appear(from: origin)
        if #available(macOS 15.4, *) { ExtensionHost.shared.miniOpened(controller) }
        if let webView = controller.tab.webView { controller.window?.makeFirstResponder(webView) }
        return controller
    }

    private init(url: URL, origin: NSRect?) {
        let spaceID = MiniQuickOpen.space.id
        tab = Tab(url: url, spaceID: spaceID)
        // Zigzag's own PDF viewer and Back to the page that opened it belong to a browser window's tabs; here the page
        // is shown as in peek, and becomes a full tab once it moves.
        tab.isPeek = true
        let screen = origin.flatMap { o in NSScreen.screens.first { $0.frame.intersects(o) } } ?? NSApp.keyWindow?.screen ?? NSScreen.main
        let area = screen?.visibleFrame ?? NSRect(origin: .zero, size: Tokens.Metric.windowDefaultSize)
        let size = Tokens.Metric.miniWindowSize
        let frame = origin.map { Self.frame(size: size, under: $0, in: area) }
            ?? Self.frame(size: size, in: area, taken: Self.all.compactMap { $0.window?.frame })

        let window = BrowserWindow(contentRect: frame)
        window.minSize = Tokens.Metric.miniWindowMinSize
        window.collectionBehavior.remove(.fullScreenPrimary)
        // Opened over a full-screen window, it stays there in the same Space instead of opening off in another one.
        if NSApp.keyWindow?.styleMask.contains(.fullScreen) == true { window.collectionBehavior.insert(.fullScreenAuxiliary) }
        window.setFrame(frame, display: false)
        super.init(window: window)
        window.delegate = self
        window.contentView = root
        window.setAccessibilityTitle(Self.name)

        strip.openButton.onClick = { [weak self] _ in self?.openInZigzag() }
        strip.title.onClick = { [weak self] _ in self?.openLocation(nil) }
        root.card.showLoading(of: tab)

        tab.host = self
        tokens.append(tab.changed.observe { [weak self] change in self?.tabChanged(change) })
        // The space's color changed, or the space went: the window follows, as a browser window does.
        tokens.append(Library.shared.changed.observe { [weak self] in self?.paint(animated: true) })
        borderlessToken = NotificationCenter.default.addObserver(forName: BrowserRootView.borderlessChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.root.needsLayout = true }
        }
        paint(animated: false)
        showPage()
        refreshStrip()
        window.trafficLightOrigin = NSPoint(x: Tokens.Sidebar.lightsX, y: Tokens.Sidebar.lightsCenter - window.trafficLightHeight / 2)
        strip.trafficLightsWidth = window.trafficLightsWidth
    }

    required init?(coder: NSCoder) { fatalError() }

    isolated deinit {
        if let borderlessToken { NotificationCenter.default.removeObserver(borderlessToken) }
    }

    /// Where a new one goes: its size, cut to fit, centered on the screen's usable area. One already at that spot
    /// moves it a step down and right, and so on, the way a Mac cascades windows; past the screen's edge it goes back
    /// to the middle.
    static func frame(size: NSSize, in area: NSRect, taken: [NSRect]) -> NSRect {
        let size = NSSize(width: min(size.width, area.width), height: min(size.height, area.height))
        let center = NSRect(x: round(area.midX - size.width / 2), y: round(area.midY - size.height / 2), width: size.width, height: size.height)
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

    /// The space it wears: its page's, or the first one if that space has gone.
    var space: SpaceInfo { Library.shared.space(tab.spaceID) ?? Library.shared.spaces[0] }

    private func paint(animated: Bool) {
        root.paint(space, isPrivate: false, animated: animated)
        strip.refreshColors()
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
            context.duration = Tokens.Motion.menuIn * Tokens.Motion.debugSlowdown
            context.timingFunction = Tokens.Motion.easeOut
            window.animator().alphaValue = 1
        }
        guard !Tokens.Motion.reduceMotion, let layer = root.layer else { return }
        let grow = CABasicAnimation(keyPath: "transform")
        grow.fromValue = NSValue(caTransform3D: Tokens.Motion.scale(Tokens.Motion.menuFrom, of: layer, around: CGPoint(x: 0.5, y: 0), flipped: false))
        grow.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        grow.duration = Tokens.Motion.menuIn * Tokens.Motion.debugSlowdown
        grow.timingFunction = Tokens.Motion.easeOut
        layer.add(grow, forKey: "appear")
    }

    /// The one way it leaves, closing or moving into Zigzag: a quick fade as it eases a touch smaller, quieter than
    /// it came.
    private func fadeAway(then done: @escaping () -> Void) {
        guard let window else { done(); return }
        isLeaving = true
        if !Tokens.Motion.reduceMotion, let layer = root.layer {
            let shrink = CABasicAnimation(keyPath: "transform")
            shrink.fromValue = NSValue(caTransform3D: layer.presentation()?.transform ?? CATransform3DIdentity)
            shrink.toValue = NSValue(caTransform3D: Tokens.Motion.scale(Tokens.Motion.menuOutScale, of: layer, flipped: false))
            shrink.duration = Tokens.Motion.menuOut * Tokens.Motion.debugSlowdown
            shrink.timingFunction = Tokens.Motion.easeOut
            shrink.fillMode = .forwards
            shrink.isRemovedOnCompletion = false
            layer.add(shrink, forKey: "leave")
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Tokens.Motion.menuOut * Tokens.Motion.debugSlowdown
            context.timingFunction = Tokens.Motion.easeOut
            window.animator().alphaValue = 0
        }, completionHandler: done)
    }

    // MARK: The page

    private func showPage() {
        root.card.show(tab.ensureWebView())
        root.card.hidePlaceholder()
    }

    private func tabChanged(_ change: Tab.Change) {
        switch change {
        case .url, .loading, .title, .favicon, .webView:
            refreshStrip()
            window?.title = tab.displayTitle
            // A new web view (the page crashed and came back, or crossed into an extension's page) takes the old one's place.
            if change == .webView, tab.webView != nil, !movedOut { showPage() }
        default: break
        }
    }

    private func refreshStrip() {
        strip.title.show(tab)
        strip.openButton.isEnabled = tab.url != nil
        strip.openButton.toolTip = Shortcuts.tooltip(String(localized: "Open in Zigzag", comment: "Tooltip of the button in a mini window's top strip that moves its page into a Zigzag window as a tab."),
                                                     for: #selector(openDocument(_:)))
        strip.needsLayout = true
    }

    // MARK: Typing an address

    /// ⌘L: the command bar over the page's name, the address in it to change; again, it goes.
    @objc func openLocation(_ sender: Any?) {
        guard !isLeaving else { return }
        if commandBar.isVisible { commandBar.dismiss(); return }
        commandBar.show(mode: .editCurrent)
    }

    /// Esc: the command bar takes its own Esc while it's up. On the page it stops a page that's loading, and otherwise
    /// does nothing: a page you were reading never closes on a stray key.
    override func cancelOperation(_ sender: Any?) {
        if tab.isLoading { tab.stopLoading() }
    }

    #if DEBUG
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

    func debugEscape() {
        if commandBar.isVisible { commandBar.debugEscape() } else { cancelOperation(nil) }
    }

    var debugState: [String: Any] {
        ["editing": commandBar.isVisible, "titleShown": !strip.title.isHidden, "title": strip.title.text,
         "openEnabled": strip.openButton.isEnabled, "webViewHere": tab.webView?.window === window, "movedOut": movedOut,
         "loading": tab.isLoading, "alpha": window?.alphaValue ?? 0,
         "fullScreenAuxiliary": window?.collectionBehavior.contains(.fullScreenAuxiliary) == true]
    }
    #endif

    // MARK: Moving into Zigzag

    /// The browser window this one's pages go to: the front everyday window, else the session brought back, else a
    /// new one. Never a private window: Zigzag Mini isn't private.
    static func browserWindow() -> BrowserWindowController {
        let manager = WindowManager.shared
        let key = manager.keyController.flatMap { $0.tabManager.isPrivate ? nil : $0 }
        return key ?? manager.controllers.last { !$0.tabManager.isPrivate } ?? manager.restoreIfNoWindows()
            ?? manager.newWindow(showCommandBar: false)
    }

    /// Moves the page, live, into a browser window as its selected tab: this window fades away first, then the page
    /// is there.
    @objc func openInZigzag(_ sender: Any? = nil) {
        guard tab.url != nil, !movedOut, !isLeaving else { return }
        commandBar.dismiss(restoringFocus: false)
        linkStatus.hide()
        fadeAway { [weak self] in self?.moveIntoZigzag() }
    }

    private func moveIntoZigzag() {
        let target = Self.browserWindow()
        movedOut = true
        pageGone.send()
        tokens.removeAll()
        Autofill.shared.forget(windowOf: window)
        if #available(macOS 15.4, *) { ExtensionHost.shared.tabClosed(tab) }
        tab.webView?.removeFromSuperview()
        tab.isPeek = false
        target.tabManager.insertAsNewTab(tab)
        window?.close()
        target.window?.makeKeyAndOrderFront(nil)
    }

    /// ⌘O, as in Arc: Open File… becomes Open in Zigzag while this window is in front.
    @objc func openDocument(_ sender: Any?) { openInZigzag(sender) }

    // MARK: Menu commands while it's in front

    /// ⌘W closes the page, and with it the window: it holds nothing else.
    @objc func closeTab(_ sender: Any?) { window?.performClose(sender) }
    @objc func goBack(_ sender: Any?) { tab.goBack() }
    @objc func goForward(_ sender: Any?) { tab.goForward() }
    @objc func reloadPage(_ sender: Any?) { tab.reload() }
    @objc func reloadPageFromOrigin(_ sender: Any?) { tab.reloadFromOrigin() }
    @objc func stopLoading(_ sender: Any?) { tab.stopLoading() }

    private static let zoomSteps: [CGFloat] = [0.5, 0.67, 0.75, 0.8, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]

    @objc func zoomIn(_ sender: Any?) {
        guard let webView = tab.webView else { return }
        setZoom(Self.zoomSteps.first { $0 > webView.pageZoom + 0.001 } ?? Self.zoomSteps.last!)
    }

    @objc func zoomOut(_ sender: Any?) {
        guard let webView = tab.webView else { return }
        setZoom(Self.zoomSteps.last { $0 < webView.pageZoom - 0.001 } ?? Self.zoomSteps.first!)
    }

    @objc func actualSize(_ sender: Any?) {
        setZoom(1)
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
        commandBar.dismiss(restoringFocus: false)
        fadeAway { [weak self] in self?.window?.close() }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        isClosing = true
        pageGone.send()
        linkStatus.hide()
        Autofill.shared.forget(windowOf: window)
        if !movedOut {
            tokens.removeAll()
            if #available(macOS 15.4, *) { ExtensionHost.shared.tabClosed(tab, windowClosing: true) }
            tab.close()
        }
        if #available(macOS 15.4, *) { ExtensionHost.shared.miniClosed(self) }
        Self.all.removeAll { $0 === self }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if #available(macOS 15.4, *) { ExtensionHost.shared.miniFocused(self) }
    }
}

// MARK: - Its menu items

extension MiniWindowController: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(openDocument(_:)):
            item.title = String(localized: "Open in Zigzag", comment: "File menu item in place of Open File… while Zigzag Mini is in front: moves its page into a browser window as a tab.")
            return tab.url != nil && !isLeaving
        case #selector(goBack(_:)): return tab.canGoBack
        case #selector(goForward(_:)): return tab.canGoForward
        case #selector(stopLoading(_:)): return tab.isLoading
        default: return !isLeaving
        }
    }
}

// MARK: - Its space

extension MiniWindowController: SpaceTinted {
    var tintSpace: SpaceInfo? { space }
}

// MARK: - The command bar over it

extension MiniWindowController: CommandBarHost {
    var commandBarOverlay: NSView { root.barLayer }
    var commandBarPageFrame: NSRect { root.card.frame }
    /// Always over the page's name, in the middle of the strip, whatever opened it.
    func commandBarAnchor(asked: NSView?) -> NSView? { strip.anchor }
    var commandBarCentersOnAnchor: Bool { true }
    var commandBarTabs: TabManager? { MiniQuickOpen.tabs }
    var commandBarTab: Tab? { tab }
    var commandBarSpace: SpaceInfo? { space }
    var commandBarIsPrivate: Bool { false }

    func commandBarWillShow() {
        linkStatus.hide()
        strip.title.isHidden = true
    }

    func commandBarRestoreFocus() {
        if let webView = tab.webView { window?.makeFirstResponder(webView) }
    }

    func commandBarDidHide() { strip.title.isHidden = false }

    /// What you choose opens here, in place of this page; an open tab is gone to in its browser window.
    func commandBarOpen(_ kind: CommandResult.Kind, modifiers: NSEvent.ModifierFlags, editing: Bool) -> Bool {
        if MiniQuickOpen.switchToTab(kind) { return true }
        guard let (url, search) = MiniQuickOpen.page(for: kind) else { return true }
        tab.isSearchTab = search
        tab.load(url)
        strip.title.isHidden = false
        commandBarRestoreFocus()
        return true
    }
}

// MARK: - Its page's requests

extension MiniWindowController: TabHost {
    var hostWindow: NSWindow? { window }

    /// One page lives here: a link that asks for a tab of its own goes to a browser window, as a sign-in popup's does.
    func tab(_ tab: Tab, openURL url: URL, disposition: OpenDisposition) {
        switch disposition {
        case .currentTab, .peek:
            tab.load(url)
        case .newWindow, .privateWindow:
            WindowManager.shared.newWindow(url: url, showCommandBar: false, isPrivate: disposition == .privateWindow)
        case .foregroundTab, .backgroundTab:
            let target = Self.browserWindow()
            target.open(url, disposition: disposition, allowSwitch: false)
            if disposition == .foregroundTab { target.window?.makeKeyAndOrderFront(nil) }
        }
    }

    func tab(_ tab: Tab, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, features: WKWindowFeatures) -> WKWebView? {
        let pending = BrowserWebView.pendingDisposition
        BrowserWebView.pendingDisposition = nil
        if pending == .newWindow || pending == .privateWindow, let url = action.request.url {
            WindowManager.shared.newWindow(url: url, showCommandBar: false, isPrivate: pending == .privateWindow)
            return nil
        }
        // Sized window.open() calls are sign-in and payment popups: their own small window, over this one.
        if pending == nil, features.width != nil || features.height != nil || features.toolbarsVisibility?.boolValue == false {
            return PopupWindowController.open(configuration: configuration, features: features, parent: window)
        }
        // A link for a new tab (target=_blank, ⌘-click, Open Link in New Tab) opens in the browser window; ⌘-click
        // and the menu's own items leave you here, a plain click takes you there.
        let background = pending != nil || (action.modifierFlags.contains(.command) && !action.modifierFlags.contains(.shift))
        let target = Self.browserWindow()
        let newTab = target.tabManager.newTab(url: action.request.url, select: !background, configuration: configuration)
        if !background { target.window?.makeKeyAndOrderFront(nil) }
        return newTab.ensureWebView()
    }

    func tabDidRequestClose(_ tab: Tab) { window?.performClose(nil) }
    func tabWantsToReturnToOpener(_ tab: Tab) {}
    func tabDidChangeFullscreen(_ tab: Tab, isFullscreen: Bool) {}

    func tab(_ tab: Tab, hoveringLink url: URL?) {
        linkStatus.show(url, in: overlay.bounds)
    }
}

// MARK: - The window's content

/// Zigzag Mini's content: the space's frame, the strip on top of it, and the page as a card, laid out as a browser
/// window lays out its page: inset by the card's gap, or meeting the window's edges when the page is borderless.
final class MiniRootView: SpaceFrameView {
    let strip = MiniStripView()
    let card = PageCardView()
    /// Over the page: the link under the pointer, a site's question, a toast.
    let overlay = PassthroughView()
    /// Over the whole window: the command bar.
    let barLayer = PassthroughView()

    init() {
        super.init(color: SpaceColor.sky.background)
        [strip, card, overlay, barLayer].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let top = Tokens.Sidebar.addressTop
        strip.frame = NSRect(x: 0, y: 0, width: bounds.width, height: top)
        // Borderless, the page runs to the window's sides and bottom, the window rounding its own corners there, and
        // its top corners take the window's curve under the strip; otherwise it floats as a card in the frame.
        let borderless = BrowserRootView.isBorderless
        let inset = borderless ? 0 : Tokens.Metric.cardInset
        card.isAttached = borderless
        card.frame = NSRect(x: inset, y: top, width: max(0, bounds.width - inset * 2), height: max(0, bounds.height - top - inset))
        overlay.frame = card.frame
        barLayer.frame = bounds
    }
}

// MARK: - The top strip

/// The strip on top: the traffic lights where a browser window has them, the page's name in the middle, and Open in
/// Zigzag at the right end, where a browser window has Reload. Dragging it moves the window.
final class MiniStripView: NSView {
    let title = MiniTitleView()
    let openButton = SidebarView.chromeButton("arrow.up.left.and.arrow.down.right",
                                              toolTip: String(localized: "Open in Zigzag", comment: "Tooltip of the button in a mini window's top strip that moves its page into a Zigzag window as a tab."))
    /// Where ⌘L's command bar opens: the address field's size, in the middle of the strip.
    let anchor = NSView()
    /// The traffic lights' width, kept clear on the left.
    var trafficLightsWidth: CGFloat = 52 { didSet { needsLayout = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        anchor.isHidden = true
        [anchor, title, openButton].forEach(addSubview)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    func refreshColors() { title.stateDidChange(animated: false) }

    override func layout() {
        super.layout()
        let center = Tokens.Sidebar.lightsCenter
        let button = Tokens.Sidebar.button
        // Its glyph's ink as far from the right edge as the lights are from the left, as Reload's in the sidebar.
        let ink = Tokens.Symbol.inkSize(openButton.symbol, size: Tokens.Sidebar.glyph).width
        openButton.frame = NSRect(x: round(bounds.width - Tokens.Sidebar.lightsX - ink / 2 - button / 2), y: center - button / 2, width: button, height: button)
        // The middle stays the middle: as wide on both sides of it as the nearer of the lights and the button allows.
        let left = Tokens.Sidebar.lightsX + trafficLightsWidth + Tokens.Sidebar.lightsGap
        let right = openButton.frame.minX - Tokens.Space.x2
        let half = max(0, min(bounds.midX - left, right - bounds.midX))
        let height = Tokens.Sidebar.addressHeight
        let width = min(title.fittingWidth, half * 2)
        title.frame = NSRect(x: round(bounds.midX - width / 2), y: center - height / 2, width: width, height: height)
        let field = min(Tokens.Metric.miniAddressWidth, max(half * 2, Tokens.Metric.miniAddressWidth / 2))
        anchor.frame = NSRect(x: round(bounds.midX - field / 2), y: center - height / 2, width: field, height: height)
    }
}

/// The page's name in the strip: its icon, the not-secure mark on a plain http page, and its title (its site, until
/// it has one) in the sidebar's row type and the space's ink. Under the pointer it shows the address field's soft
/// fill, and a click opens the command bar over it, as the sidebar's address does.
final class MiniTitleView: InteractiveView {
    private let icon = FaviconView()
    private let mark = NSImageView()
    private let label = Label("", font: Tokens.Font.sidebarRow(), color: Tokens.Color.textPrimary)
    private var themeToken: SignalToken?
    var text: String { label.stringValue }

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.cornerRadius = Tokens.Sidebar.addressRadius
        layer?.cornerCurve = .continuous
        mark.imageScaling = .scaleNone
        mark.image = Tokens.Symbol.image(SitePanel.notSecureSymbol, size: Tokens.Symbol.inline)
        mark.toolTip = SitePanel.notSecure
        mark.isHidden = true
        label.lineBreakMode = .byTruncatingTail
        [icon, mark, label].forEach(addSubview)
        setAccessibilityRole(.button)
        setAccessibilityHelp(String(localized: "Opens the command bar", comment: "Accessibility help of the address in the sidebar."))
        themeToken = Brand.themeChanged.observe { [weak self] in self?.stateDidChange(animated: false) }
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ tab: Tab) {
        label.stringValue = tab.displayTitle
        icon.image = tab.favicon
        icon.isLoading = tab.isLoading
        mark.isHidden = tab.url?.scheme != "http"
        setAccessibilityLabel(mark.isHidden ? label.stringValue
                              : String(localized: "\(label.stringValue), \(SitePanel.notSecure)", comment: "Accessibility label of the address in the sidebar on a plain http page: the site, then that it's not secure."))
        needsLayout = true
    }

    /// As wide as the icon, the mark and the whole title want, with the field's padding either side.
    var fittingWidth: CGFloat {
        let pad = Tokens.Space.x3
        var width = pad * 2 + Tokens.Sidebar.favicon + Tokens.Sidebar.iconGap + ceil(label.textWidth)
        if !mark.isHidden { width += Tokens.Space.x3 + Tokens.Space.x1 }
        return width
    }

    override func layout() {
        super.layout()
        let pad = Tokens.Space.x3
        let side = Tokens.Sidebar.favicon
        icon.frame = NSRect(x: pad, y: round((bounds.height - side) / 2), width: side, height: side)
        var x = icon.frame.maxX + Tokens.Sidebar.iconGap
        if !mark.isHidden {
            mark.frame = NSRect(x: x, y: 0, width: Tokens.Space.x3, height: bounds.height)
            x = mark.frame.maxX + Tokens.Space.x1
        }
        let h = label.lineHeight
        label.frame = NSRect(x: x - Label.inset, y: round((bounds.height - h) / 2), width: max(0, bounds.width - pad - x + Label.inset * 2), height: h)
    }

    override func stateDidChange(animated: Bool) {
        // Plain on the frame at rest; under the pointer, the sidebar address's soft field, a step back when pressed.
        let fill: NSColor? = isPressed ? Tokens.Chrome.fieldPressed : isHovered ? Tokens.Chrome.field : nil
        layer?.set(backgroundColor: fill.map { cgColor($0) }, animated: animated && !isHovered)
        let theme = Brand.Theme.for(self)
        label.textColor = theme.rowInk
        mark.contentTintColor = theme.quietInk
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stateDidChange(animated: false)
    }
}

// MARK: - As extensions see it

/// Zigzag Mini, for extensions: a popup-type window holding its one tab, as a sign-in popup is.
@available(macOS 15.4, *)
extension MiniWindowController: WKWebExtensionWindow {
    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] { movedOut ? [] : [tab] }
    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? { movedOut ? nil : tab }
    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { .popup }
    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState { window?.isMiniaturized == true ? .minimized : .normal }
    func isPrivate(for context: WKWebExtensionContext) -> Bool { false }
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
    func promptShows(_ tab: Tab) -> Bool { promptHolds(tab) }
    var promptIsPrivate: Bool { false }
    var promptAccent: NSColor { Brand.Theme.of(space).accent }
    /// Its one page never changes places; it only leaves, into Zigzag or with the window.
    func observePromptTabs(_ body: @escaping () -> Void) -> SignalToken? { pageGone.observe { _ in body() } }
    var promptPageViews: [NSView] { [root.card] }
    func clearForPrompt() {
        linkStatus.hide()
        commandBar.dismiss()
    }
    var promptIsCovered: Bool { false }
    var promptAnchor: NSView? { strip }
    func promptToast(_ text: String, symbol: String, duration: TimeInterval) {
        Toast.show(text, symbol: symbol, duration: duration, over: overlay, area: overlay.bounds)
    }
}
