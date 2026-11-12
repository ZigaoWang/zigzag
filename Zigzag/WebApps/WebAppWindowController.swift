import AppKit
import WebKit

/// A site installed as an app, in a window of its own, as a web app is in Chrome or Safari: a slim toolbar in the
/// page's own color (`PageBar`) with back, forward and reload and the app's name, the page under it edge to edge, no
/// sidebar; or, with the toolbar off, just the page with the traffic lights over it. Its page is a real tab on
/// the app's profile, so you stay signed in and extensions, blocking and passwords work as anywhere. A link you click to
/// another site opens in the browser window. Its frame is remembered for the next time. Opened only by the app's small
/// app (`ZigzagWebApp`), which quits when this window closes.
final class WebAppWindowController: NSWindowController, NSWindowDelegate {
    override func noResponder(for eventSelector: Selector) {
        if QuietKeys.passQuietly(eventSelector, NSApp.currentEvent) { return }
        super.noResponder(for: eventSelector)
    }

    private(set) static var all: [WebAppWindowController] = []
    static func controller(for id: String) -> WebAppWindowController? { all.first { $0.app.id == id } }
    /// When each app's window last closed: the small app becoming active as it goes asks for it again at once, which
    /// isn't you asking.
    private static var closedAt: [String: Date] = [:]

    let app: WebApp
    let tab: Tab
    private let root = WebAppRootView()
    private var strip: WebAppStripView { root.strip }
    var overlay: PassthroughView { root.overlay }
    private lazy var linkStatus = LinkStatusController(overlay: overlay)
    private var tokens: [SignalToken] = []
    private let pageGone = Signal<Void>()
    private var isClosing = false

    /// Shows the app's window, opening it if it isn't, and brings it forward on its own.
    static func show(_ app: WebApp) {
        if let open = controller(for: app.id) { open.bringForward(); return }
        if let closed = closedAt[app.id], Date().timeIntervalSince(closed) < 1.5 { return }
        let controller = WebAppWindowController(app: app)
        all.append(controller)
        Diagnostics.note("Web app opened", site: app.url.host())
        controller.bringForward()
        if let webView = controller.tab.webView { controller.window?.makeFirstResponder(webView) }
    }

    /// The space the window wears and the page's profile comes from: the one it was installed from, else another of
    /// that profile's, else the first.
    static func space(for app: WebApp) -> UUID {
        let library = Library.shared
        if let space = library.space(app.spaceID), library.profileID(ofSpace: space.id) == app.profileID { return space.id }
        return library.spaces(in: app.profileID).first?.id ?? library.spaces[0].id
    }

    static func frameName(_ id: String) -> String { "WebApp \(id)" }

    private init(app: WebApp) {
        self.app = app
        tab = Tab(url: app.url, spaceID: Self.space(for: app))
        // As in Zigzag Mini: no PDF viewer or mini player of a browser window's tabs.
        tab.isPeek = true
        tab.keepsSite = true
        let area = NSScreen.main?.visibleFrame ?? NSRect(origin: .zero, size: Tokens.Metric.windowDefaultSize)
        let size = NSSize(width: min(Tokens.Metric.webAppWindowSize.width, area.width), height: min(Tokens.Metric.webAppWindowSize.height, area.height))
        let frame = MiniWindowController.frame(size: size, in: area, taken: Self.all.compactMap { $0.window?.frame })
        let window = BrowserWindow(contentRect: frame)
        window.minSize = Tokens.Metric.miniWindowMinSize
        window.tabbingMode = .disallowed
        window.setFrame(frame, display: false)
        super.init(window: window)
        window.delegate = self
        window.contentView = root
        window.title = app.name
        window.setAccessibilityTitle(app.name)
        // Where you left it last time, and remembered from now on.
        window.setFrameUsingName(Self.frameName(app.id))
        window.setFrameAutosaveName(Self.frameName(app.id))

        strip.title.stringValue = app.name
        strip.back.onClick = { [weak self] _ in self?.tab.goBack() }
        strip.forward.onClick = { [weak self] _ in self?.tab.goForward() }
        strip.reload.onClick = { [weak self] _ in
            guard let tab = self?.tab else { return }
            tab.isLoading ? tab.stopLoading() : tab.reload()
        }
        root.card.showLoading(of: tab)
        tab.host = self
        tokens.append(tab.changed.observe { [weak self] change in self?.tabChanged(change) })
        // Its toolbar turned on or off, here or in Settings.
        tokens.append(WebAppStore.shared.changed.observe { [weak self] in self?.applyToolbar() })
        root.dragStrip.menuEntries = { [weak self] in self?.toolbarMenu() ?? [] }
        strip.menuEntries = root.dragStrip.menuEntries
        root.card.show(tab.ensureWebView())
        root.card.hidePlaceholder()
        refreshStrip()
        refreshBar(animated: false)
        strip.trafficLightsWidth = window.trafficLightsWidth
        applyToolbar()
    }

    required init?(coder: NSCoder) { fatalError() }

    var space: SpaceInfo { Library.shared.space(tab.spaceID) ?? Library.shared.spaces[0] }

    /// The app as it's saved now: its toolbar can change while the window is open.
    private var current: WebApp { WebAppStore.shared.app(app.id) ?? app }

    /// The toolbar, or just the page with the traffic lights over it, as the app is set.
    private func applyToolbar() {
        guard let window = window as? BrowserWindow else { return }
        let shows = current.showsToolbar
        root.showsToolbar = shows
        // Centered in the toolbar; without it, where a window's title bar would hold them.
        let top = shows ? Tokens.Metric.miniStripHeight : Tokens.Metric.webAppTitleBarHeight
        window.trafficLightOrigin = NSPoint(x: Tokens.Sidebar.lightsX, y: round((top - window.trafficLightHeight) / 2))
        root.dragStrip.lightsEnd = Tokens.Sidebar.lightsX + window.trafficLightsWidth
    }

    /// The toolbar in the page's color, from the site's theme color, the manifest's, or the page's own.
    private func refreshBar(animated: Bool) {
        let manifest = current.themeColor.flatMap(DarkPages.color(hex:))
        root.bar.show(bar: PageBar.color(for: tab, fallback: manifest), page: tab.pageColor, animated: animated)
        root.color = root.bar.color
        strip.appearance = root.bar.inkAppearance
    }

    /// The toolbar's own menu, on a right-click on it, or on the strip the traffic lights sit in while it's off.
    private func toolbarMenu() -> [MenuPanel.Entry] {
        [.item(.init(title: Self.toolbarTitle(showing: current.showsToolbar), symbol: "menubar.rectangle") { [weak self] in self?.toggleToolbar(nil) })]
    }

    static func toolbarTitle(showing: Bool) -> String {
        showing ? String(localized: "Hide Toolbar", comment: "Menu item in an installed app's window (View menu, and its toolbar's right-click menu): leaves just the page with the traffic lights over it.")
                : String(localized: "Show Toolbar", comment: "Menu item in an installed app's window (View menu, and the right-click menu of the strip at its top): brings back back, forward, reload and the app's name.")
    }

    @objc func toggleToolbar(_ sender: Any?) {
        WebAppStore.shared.setShowsToolbar(!current.showsToolbar, for: app.id)
    }

    /// Only this window comes forward, not the browser windows. It's made key first, so activating brings up just it
    /// (activation raises the key and main windows only). Since macOS 14 an app may take the front only when the app
    /// in front lets it: the small app, just opened or clicked and so in front, steps aside for Zigzag before it asks
    /// (`NSApp.yieldActivation`), and `NSApp.activate()` is the request that honors that.
    func bringForward() {
        guard let window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        if !NSApp.isActive { MiniLinkWake.activatingForOneWindow() }
        NSApp.activate()
    }

    private func tabChanged(_ change: Tab.Change) {
        switch change {
        case .url, .loading, .title, .navigation, .webView:
            refreshStrip()
            if change == .webView, tab.webView != nil, !isClosing { root.card.show(tab.webView) }
            if change == .webView || change == .loading { refreshBar(animated: false) }
        case .themeColor, .darkPage:
            refreshBar(animated: true)
        default: break
        }
    }

    /// The app's name; on another site (a sign-in page it went to), that site's address instead, so you always see
    /// where you're typing.
    static func stripTitle(app: WebApp, page: URL?) -> String {
        guard let page, let host = page.host(), Tab.site(of: page) != Tab.site(of: app.url) else { return app.name }
        return host
    }

    private func refreshStrip() {
        strip.title.stringValue = Self.stripTitle(app: app, page: tab.url)
        strip.notSecure = tab.url?.scheme == "http"
        strip.back.isEnabled = tab.canGoBack
        strip.forward.isEnabled = tab.canGoForward
        strip.reload.symbol = tab.isLoading ? "xmark" : "arrow.clockwise"
        strip.needsLayout = true
    }

    // MARK: Menu commands while it's in front

    @objc func closeTab(_ sender: Any?) { window?.performClose(sender) }
    @objc func goBack(_ sender: Any?) { tab.goBack() }
    @objc func goForward(_ sender: Any?) { tab.goForward() }
    @objc func reloadPage(_ sender: Any?) { tab.reload() }
    @objc func reloadPageFromOrigin(_ sender: Any?) { tab.reloadFromOrigin() }
    @objc func stopLoading(_ sender: Any?) { tab.stopLoading() }

    @objc func copyPageURL(_ sender: Any?) {
        guard let url = tab.url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        Toast.show(String(localized: "Link copied", comment: "Toast after the page's address is copied."), symbol: "link", over: overlay, area: overlay.bounds)
    }

    /// The app menu's Quit: the app quits, as any Mac app does, and Zigzag with its other windows stays.
    @objc func quitWebApp(_ sender: Any?) { window?.performClose(sender) }

    /// The app menu's Hide: this window goes away until the app is chosen again (its Dock icon, ⌘Tab), and Zigzag's
    /// other windows stay where they are. With no other window of Zigzag's showing, Zigzag steps back so the app
    /// you were in before comes forward, as hiding an app does.
    @objc func hideWebApp(_ sender: Any?) {
        guard let window else { return }
        window.orderOut(sender)
        let others = NSApp.windows.contains { $0 !== window && $0.isVisible && $0.level == .normal && !($0 is NSPanel) }
        if !others { NSApp.hide(sender) }
        WebAppMenuBar.shared?.follow(NSApp.keyWindow === window ? nil : NSApp.keyWindow)
    }

    /// File › Open in Zigzag: the page as it is now, in a tab of a browser window.
    @objc func openInBrowser(_ sender: Any?) {
        guard let url = tab.url else { return }
        let target = MiniWindowController.browserWindow()
        target.open(url, disposition: .foregroundTab, allowSwitch: false)
        target.window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    @objc func zoomIn(_ sender: Any?) {
        guard let webView = tab.webView else { return }
        setZoom(ZoomLevels.step(webView.pageZoom, by: 1))
    }

    @objc func zoomOut(_ sender: Any?) {
        guard let webView = tab.webView else { return }
        setZoom(ZoomLevels.step(webView.pageZoom, by: -1))
    }

    @objc func actualSize(_ sender: Any?) { setZoom(1) }

    private func setZoom(_ zoom: CGFloat) {
        guard let webView = tab.webView, let url = tab.url else { return }
        webView.pageZoom = zoom
        ZoomLevels.set(zoom, for: url)
    }

    // MARK: Closing

    func windowWillClose(_ notification: Notification) {
        isClosing = true
        Self.closedAt[app.id] = Date()
        pageGone.send()
        linkStatus.hide()
        Autofill.shared.forget(windowOf: window)
        tokens.removeAll()
        if #available(macOS 15.4, *) { ExtensionCenter.tabClosed(tab, windowClosing: true) }
        tab.close()
        Self.all.removeAll { $0 === self }
        // The small app goes with its window, so its Dock icon does too.
        WebAppStore.runningLauncher(of: app.id).forEach { $0.terminate() }
    }

    #if DEBUG
    var debugState: [String: Any] {
        ["id": app.id, "name": app.name, "title": strip.title.stringValue, "url": tab.url?.absoluteString ?? "",
         "profile": Library.shared.directory.profile(tab.profile.id)?.name ?? "", "space": space.name,
         "store": tab.webView?.configuration.websiteDataStore.identifier?.uuidString ?? "default",
         "frame": window.map { NSStringFromRect($0.frame) } ?? "", "key": window?.isKeyWindow == true,
         "canGoBack": tab.canGoBack, "loading": tab.isLoading, "showsToolbar": root.showsToolbar, "visible": window?.isVisible == true,
         "bar": root.bar.color.flatMap { $0.usingColorSpace(.sRGB) }.map(DarkPages.hex) ?? ""]
    }
    #endif
}

extension WebAppWindowController: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(goBack(_:)): return tab.canGoBack
        case #selector(goForward(_:)): return tab.canGoForward
        case #selector(stopLoading(_:)): return tab.isLoading
        case #selector(copyPageURL(_:)), #selector(openInBrowser(_:)): return tab.url != nil
        case #selector(toggleToolbar(_:)):
            item.title = Self.toolbarTitle(showing: current.showsToolbar)
            return true
        default: return true
        }
    }
}

extension WebAppWindowController: SpaceTinted {
    var tintSpace: SpaceInfo? { space }
}

extension WebAppWindowController: SwipeArrowHost {
    var swipeArrowLayer: NSView { root.barLayer }
}

// MARK: - Its page's requests

extension WebAppWindowController: TabHost {
    var hostWindow: NSWindow? { window }

    /// The site stays here; a link for a tab of its own, or one to another site, goes to the browser window.
    func tab(_ tab: Tab, openURL url: URL, disposition: OpenDisposition) {
        switch disposition {
        case .currentTab, .peek:
            tab.load(url)
        case .newWindow, .privateWindow:
            WindowManager.shared.newWindow(url: url, showCommandBar: false, isPrivate: disposition == .privateWindow)
        case .foregroundTab, .backgroundTab:
            let target = MiniWindowController.browserWindow()
            target.open(url, disposition: disposition, allowSwitch: false)
            if disposition == .foregroundTab {
                target.window?.makeKeyAndOrderFront(nil)
                NSApp.activate()
            }
        }
    }

    func tab(_ tab: Tab, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, features: WKWindowFeatures) -> WKWebView? {
        let pending = BrowserWebView.takePendingDisposition(for: tab.webView)
        if pending == .newWindow || pending == .privateWindow, let url = action.request.url {
            WindowManager.shared.newWindow(url: url, showCommandBar: false, isPrivate: pending == .privateWindow)
            return nil
        }
        // Sign-in and payment popups: their own small window, over this one.
        if pending == nil, features.width != nil || features.height != nil || features.toolbarsVisibility?.boolValue == false {
            return PopupWindowController.open(configuration: configuration, features: features, parent: window)
        }
        // A plain click on a link to the same site that asks for a new tab: it opens here, as the app is that site.
        let modified = action.modifierFlags.contains(.command) || action.modifierFlags.contains(.shift)
        if pending == nil, !modified, let url = action.request.url, let here = tab.url, !Tab.leavesSite(from: here, to: url) {
            tab.load(url)
            return nil
        }
        let background = pending != nil || (action.modifierFlags.contains(.command) && !action.modifierFlags.contains(.shift))
        let target = MiniWindowController.browserWindow()
        let newTab = target.tabManager.newTab(url: nil, select: !background, configuration: configuration)
        if !background {
            target.window?.makeKeyAndOrderFront(nil)
            NSApp.activate()
        }
        return newTab.ensureWebView()
    }

    func tabDidRequestClose(_ tab: Tab) { window?.performClose(nil) }
    func tabWantsToReturnToOpener(_ tab: Tab) {}
    func tabWantsToBeShown(_ tab: Tab) { bringForward() }
    func tab(_ tab: Tab, hoveringLink url: URL?) { linkStatus.show(url, in: overlay.bounds) }
}

// MARK: - Its page's questions

extension WebAppWindowController: PromptHost {
    var promptOverlay: NSView { overlay }
    func pageFrame(showing tab: Tab) -> NSRect? { promptHolds(tab) ? overlay.bounds : nil }
    var focusedPaneFrame: NSRect { overlay.bounds }
    var promptFrontTab: Tab? { isClosing ? nil : tab }
    func promptHolds(_ tab: Tab) -> Bool { tab === self.tab && !isClosing }
    func promptShows(_ tab: Tab) -> Bool { promptHolds(tab) }
    var promptIsPrivate: Bool { false }
    var promptAccent: NSColor { Brand.Theme.of(space).accent }
    func observePromptTabs(_ body: @escaping () -> Void) -> SignalToken? { pageGone.observe { _ in body() } }
    var promptPageViews: [NSView] { [root.card] }
    func clearForPrompt() { linkStatus.hide() }
    var promptIsCovered: Bool { false }
    var promptAnchor: NSView? { strip }
    func promptToast(_ text: String, symbol: String, duration: TimeInterval) {
        Toast.show(text, symbol: symbol, duration: duration, over: overlay, area: overlay.bounds)
    }
}
// MARK: - The window's content

/// The toolbar on top in the page's color and the page under it, edge to edge; the window rounds its own corners.
/// With the toolbar off, the page fills the window and a strip along its top, where a title bar would be, still moves
/// it.
final class WebAppRootView: ColorView {
    let bar = PageBarView()
    let strip = WebAppStripView()
    let card = PageCardView()
    let dragStrip = WebAppDragStrip()
    let overlay = PassthroughView()
    let barLayer = PassthroughView()
    var showsToolbar = true {
        didSet {
            guard showsToolbar != oldValue else { return }
            bar.isHidden = !showsToolbar
            strip.isHidden = !showsToolbar
            dragStrip.isHidden = showsToolbar
            needsLayout = true
        }
    }

    init() {
        super.init(color: Tokens.Color.cardBackground)
        dragStrip.isHidden = true
        [bar, strip, card, dragStrip, overlay, barLayer].forEach(addSubview)
        card.isEdgeToEdge = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let top = showsToolbar ? Tokens.Metric.miniStripHeight : 0
        bar.frame = NSRect(x: 0, y: 0, width: bounds.width, height: top)
        strip.frame = bar.frame
        card.frame = NSRect(x: 0, y: top, width: bounds.width, height: max(0, bounds.height - top))
        dragStrip.frame = NSRect(x: 0, y: 0, width: bounds.width, height: min(bounds.height, Tokens.Metric.webAppTitleBarHeight))
        overlay.frame = card.frame
        barLayer.frame = bounds
    }
}

/// With the toolbar off, the top of the window still moves it, as a title bar would, without taking the page's
/// clicks: a thin band across the whole top, and the title bar's full height around the traffic lights. A
/// double-click zooms the window; a right-click offers the toolbar back.
final class WebAppDragStrip: NSView {
    /// Where the traffic lights end, from the window's leading edge.
    var lightsEnd: CGFloat = 70 { didSet { needsLayout = true } }
    var menuEntries: (() -> [MenuPanel.Entry])?

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    /// The parts of it that take the pointer, in its own coordinates.
    var grabAreas: [NSRect] {
        [NSRect(x: 0, y: 0, width: bounds.width, height: min(bounds.height, Tokens.Metric.webAppDragBand)),
         NSRect(x: 0, y: 0, width: lightsEnd + Tokens.Space.x3, height: bounds.height)]
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, let superview else { return nil }
        let local = convert(point, from: superview)
        return grabAreas.contains { $0.contains(local) } ? self : nil
    }

    override func mouseDown(with event: NSEvent) { window?.titleBarMouseDown(event) }

    override func rightMouseDown(with event: NSEvent) {
        guard let entries = menuEntries?(), !entries.isEmpty else { return }
        MenuPanel.show(entries, from: self, placement: .at(convert(event.locationInWindow, from: nil)))
    }
}

/// The traffic lights, back, forward and reload after them on the lights' center line, and the app's name in the
/// middle in a window title's type. Its ink comes from the bar's color (its appearance, set by the window). Dragging
/// it moves the window, a double-click zooms it, and a right-click offers to hide it.
final class WebAppStripView: NSView {
    let back = WebAppStripView.button("chevron.left", toolTip: String(localized: "Back", comment: "Tooltip of a button in the strip on top of each page of a split view: goes back."))
    let forward = WebAppStripView.button("chevron.right", toolTip: String(localized: "Forward", comment: "Tooltip of a button in the strip on top of each page of a split view: goes forward."))
    let reload = WebAppStripView.button("arrow.clockwise", toolTip: String(localized: "Reload", comment: "Tooltip of a button in the strip on top of each page of a split view: reloads the page."))
    let title = Label("", font: .titleBarFont(ofSize: 0), color: .labelColor)
    private let mark = NSImageView()
    var notSecure = false { didSet { mark.isHidden = !notSecure } }
    var trafficLightsWidth: CGFloat = 52 { didSet { needsLayout = true } }
    var menuEntries: (() -> [MenuPanel.Entry])?
    private var keyTokens: [NSObjectProtocol] = []

    static func button(_ symbol: String, toolTip: String) -> IconButton {
        let button = IconButton(symbol: symbol, size: Tokens.Pane.button, symbolSize: Tokens.Pane.glyph, toolTip: toolTip)
        // On the page's color, not the frame's: the neutral fills, which show on any color.
        button.isOnPage = true
        return button
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        title.lineBreakMode = .byTruncatingTail
        title.alignment = .center
        mark.imageScaling = .scaleNone
        mark.image = Tokens.Symbol.image(SitePanel.notSecureSymbol, size: Tokens.Symbol.inline)
        mark.toolTip = SitePanel.notSecure
        mark.contentTintColor = .secondaryLabelColor
        mark.isHidden = true
        [back, forward, reload, mark, title].forEach(addSubview)
        setAccessibilityRole(.toolbar)
    }

    required init?(coder: NSCoder) { fatalError() }

    isolated deinit { keyTokens.forEach(NotificationCenter.default.removeObserver) }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }
    override func mouseDown(with event: NSEvent) { window?.titleBarMouseDown(event) }

    override func rightMouseDown(with event: NSEvent) {
        guard let entries = menuEntries?(), !entries.isEmpty else { return }
        MenuPanel.show(entries, from: self, placement: .at(convert(event.locationInWindow, from: nil)))
    }

    /// A window's title dims while the window isn't the one you're in, as every Mac window's does.
    private func refreshTitle() {
        title.textColor = window?.isKeyWindow == false ? .tertiaryLabelColor : .labelColor
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        keyTokens.forEach(NotificationCenter.default.removeObserver)
        keyTokens = []
        guard let window else { return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            keyTokens.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshTitle() }
            })
        }
        refreshTitle()
    }

    override func layout() {
        super.layout()
        let mid = bounds.height / 2, b = Tokens.Pane.button
        var x = Tokens.Sidebar.lightsX + trafficLightsWidth + Tokens.Space.x2
        for button in [back, forward, reload] {
            button.frame = NSRect(x: x, y: round(mid - b / 2), width: b, height: b)
            x += b
        }
        // The name stays in the middle of the window, as wide as the room beside the buttons allows.
        let half = max(0, bounds.midX - x - Tokens.Space.x2)
        let markRoom: CGFloat = mark.isHidden ? 0 : Tokens.Space.x4
        let width = min(title.inkWidth + 4 + markRoom, half * 2)
        let h = title.lineHeight
        let left = round(bounds.midX - width / 2)
        mark.frame = NSRect(x: left, y: 0, width: Tokens.Space.x3, height: bounds.height)
        title.frame = NSRect(x: left + markRoom - Label.inset, y: round(mid - h / 2), width: max(0, width - markRoom + Label.inset * 2), height: h)
    }
}
