import AppKit
import WebKit

/// A site installed as an app, in a window of its own: Zigzag Mini's quiet frame in the color of the space it was
/// installed from, a slim strip with back, forward and reload and the app's name, no sidebar. Its page is a real tab on
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
        tokens.append(Library.shared.changed.observe { [weak self] in
            self?.paint(animated: true)
        })
        paint(animated: false)
        root.card.show(tab.ensureWebView())
        root.card.hidePlaceholder()
        refreshStrip()
        window.trafficLightOrigin = NSPoint(x: Tokens.Sidebar.lightsX, y: round((Tokens.Metric.miniStripHeight - window.trafficLightHeight) / 2))
        strip.trafficLightsWidth = window.trafficLightsWidth
    }

    required init?(coder: NSCoder) { fatalError() }

    var space: SpaceInfo { Library.shared.space(tab.spaceID) ?? Library.shared.spaces[0] }

    private func paint(animated: Bool) {
        root.paint(space, isPrivate: false, animated: animated)
        strip.refreshColors()
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

    private static let zoomSteps: [CGFloat] = [0.5, 0.67, 0.75, 0.8, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]

    @objc func zoomIn(_ sender: Any?) {
        guard let webView = tab.webView else { return }
        setZoom(Self.zoomSteps.first { $0 > webView.pageZoom + 0.001 } ?? Self.zoomSteps.last!)
    }

    @objc func zoomOut(_ sender: Any?) {
        guard let webView = tab.webView else { return }
        setZoom(Self.zoomSteps.last { $0 < webView.pageZoom - 0.001 } ?? Self.zoomSteps.first!)
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
         "canGoBack": tab.canGoBack, "loading": tab.isLoading]
    }
    #endif
}

extension WebAppWindowController: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(goBack(_:)): return tab.canGoBack
        case #selector(goForward(_:)): return tab.canGoForward
        case #selector(stopLoading(_:)): return tab.isLoading
        case #selector(copyPageURL(_:)): return tab.url != nil
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

/// The space's frame, the strip on top, and the page as a card in a thin frame of the color, as in Zigzag Mini.
final class WebAppRootView: SpaceFrameView {
    let strip = WebAppStripView()
    let card = PageCardView()
    let overlay = PassthroughView()
    let barLayer = PassthroughView()

    init() {
        super.init(color: SpaceColor.sky.background)
        [strip, card, overlay, barLayer].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var glassFrame: NSRect {
        guard BrowserRootView.isBorderless else { return bounds }
        return NSRect(x: 0, y: 0, width: bounds.width, height: min(bounds.height, Tokens.Metric.miniStripHeight))
    }

    override func layout() {
        super.layout()
        let borderless = BrowserRootView.isBorderless
        let top = Tokens.Metric.miniStripHeight
        strip.frame = NSRect(x: 0, y: 0, width: bounds.width, height: top)
        card.isAttached = borderless
        card.squaresLeftCorners = (borderless, borderless)
        card.squaresRightCorners = (borderless, borderless)
        let inset = borderless ? 0 : Tokens.Metric.miniFrame
        card.frame = NSRect(x: inset, y: top, width: max(0, bounds.width - inset * 2), height: max(0, bounds.height - top - inset))
        overlay.frame = card.frame
        barLayer.frame = bounds
    }
}

/// The traffic lights, back, forward and reload after them, and the app's name in the middle, quiet. Dragging it
/// moves the window.
final class WebAppStripView: NSView {
    let back = WebAppStripView.button("chevron.left", toolTip: String(localized: "Back", comment: "Tooltip of a button in the strip on top of each page of a split view: goes back."))
    let forward = WebAppStripView.button("chevron.right", toolTip: String(localized: "Forward", comment: "Tooltip of a button in the strip on top of each page of a split view: goes forward."))
    let reload = WebAppStripView.button("arrow.clockwise", toolTip: String(localized: "Reload", comment: "Tooltip of a button in the strip on top of each page of a split view: reloads the page."))
    let title = Label("", font: .systemFont(ofSize: Tokens.Pane.addressText, weight: .medium), color: Tokens.Color.textSecondary)
    private let mark = NSImageView()
    var notSecure = false { didSet { mark.isHidden = !notSecure } }
    var trafficLightsWidth: CGFloat = 52 { didSet { needsLayout = true } }
    private var themeToken: SignalToken?

    static func button(_ symbol: String, toolTip: String) -> IconButton {
        let button = IconButton(symbol: symbol, size: Tokens.Pane.button, symbolSize: Tokens.Pane.glyph, toolTip: toolTip)
        button.isChrome = true
        return button
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        title.lineBreakMode = .byTruncatingTail
        title.alignment = .center
        mark.imageScaling = .scaleNone
        mark.image = Tokens.Symbol.image(SitePanel.notSecureSymbol, size: Tokens.Symbol.inline)
        mark.toolTip = SitePanel.notSecure
        mark.isHidden = true
        [back, forward, reload, mark, title].forEach(addSubview)
        themeToken = Brand.themeChanged.observe { [weak self] in self?.refreshColors() }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    func refreshColors() {
        let theme = Brand.Theme.for(self)
        title.textColor = theme.rowInk
        mark.contentTintColor = theme.quietInk
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshColors()
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
