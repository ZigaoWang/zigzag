import AppKit
import WebKit

/// Sign-in and payment popups (window.open with a size). A small real window that shows
/// which site you are talking to, keeps window.opener working, and closes itself when the page does.
final class PopupWindowController: NSWindowController, NSWindowDelegate, WKUIDelegate, WKNavigationDelegate {
    /// The last to be asked about a key: one nothing took goes by quietly (`QuietKeys`).
    override func noResponder(for eventSelector: Selector) {
        if QuietKeys.passQuietly(eventSelector, NSApp.currentEvent) { return }
        super.noResponder(for: eventSelector)
    }

    private static var open: Set<PopupWindowController> = []
    /// Every popup window, for extensions: 1Password fills sign-in popups as it does tabs.
    static var all: [PopupWindowController] { Array(open) }
    /// The popup you're in, if it's one extensions may see.
    static var key: PopupWindowController? { open.first { !$0.isPrivate && $0.window?.isKeyWindow == true } }
    /// The popup's page, as extensions see it: one tab in a popup window, as in Chrome.
    private(set) lazy var tab = PopupTab(popup: self)
    /// Private popups stay out of extensions' sight, like private tabs.
    var isPrivate: Bool { !webView.configuration.websiteDataStore.isPersistent }

    let webView: WKWebView
    private var observations: [NSKeyValueObservation] = []
    private let header = PopupHeaderView()
    /// Window › Keep on Top for this window, at the strip's right end: a pin, filled while it's on.
    private let pinButton: IconButton = {
        let button = IconButton(symbol: "pin", size: Tokens.Pane.button, symbolSize: Tokens.Pane.glyph, toolTip: KeepOnTop.title)
        button.isChrome = true
        return button
    }()
    /// Copy Link and Open in New Tab, beside Keep on Top, as in Zigzag Mini's strip.
    private let copyButton: IconButton = {
        let button = IconButton(symbol: "link", size: Tokens.Pane.button, symbolSize: Tokens.Pane.glyph,
                                toolTip: Shortcuts.tooltip(PopupWindowController.copyLinkTitle, for: #selector(PopupWindowController.copyPageURL(_:))))
        button.isChrome = true
        return button
    }()
    private let openButton: IconButton = {
        let button = IconButton(symbol: "arrow.up.forward.app", size: Tokens.Pane.button, symbolSize: Tokens.Pane.glyph,
                                toolTip: Shortcuts.tooltip(PopupWindowController.openInTabTitle, for: #selector(PopupWindowController.openDocument(_:))))
        button.isChrome = true
        return button
    }()
    static var copyLinkTitle: String { String(localized: "Copy Link", comment: "Edit menu item.") }
    static var openInTabTitle: String {
        String(localized: "Open in New Tab", comment: "Button in a pop-up window's top strip, its right-click menu and the File menu while it's in front: moves its page into a tab of the browser window.")
    }
    /// Over the page, for the find bar and toasts.
    private let overlay = PassthroughView()
    /// ⌘F: made the first time it's asked for.
    private var madeFindBar: FindBarController?
    private var findBar: FindBarController {
        if let madeFindBar { return madeFindBar }
        let made = FindBarController(window: self)
        madeFindBar = made
        return made
    }
    private var keepOnTopToken: NSObjectProtocol?
    private var parentObserver: Any?
    /// The browser window that opened it, where news about it (a pop-up it tried to open) is shown.
    private(set) weak var parentWindow: NSWindow?
    /// The tab that opened it: WebRTC questions go to its window, and its private-window choices apply here
    /// (`WebRTCProtection`).
    private(set) weak var opener: Tab?
    /// Copy of the opener's choices, kept after it closes.
    private var openerWebRTCChoices: [String: Bool] = [:]
    /// The opener's choices while it's open, the copy after.
    var webRTCChoices: [String: Bool] {
        if let opener { openerWebRTCChoices = opener.webRTCHere }
        return openerWebRTCChoices
    }
    /// Same for JavaScript (`SiteJavaScript`).
    private var openerJavaScriptChoices: [String: Bool] = [:]
    var javaScriptChoices: [String: Bool] {
        if let opener { openerJavaScriptChoices = opener.javaScriptHere }
        return openerJavaScriptChoices
    }
    /// The strip at the top with the traffic lights and whose page it is.
    static let headerHeight = Tokens.Space.x8 + Tokens.Space.x1
    private var lastCrash: Date?
    /// True until the pop-up question is answered: the window exists (so `window.opener` works) but nothing is
    /// fetched, so a denied pop-up makes no request.
    private var isHoldingFirstLoad = false
    /// The first request, loaded if the answer is Mini. Later navigations of the held window can't change what the
    /// card asked about.
    private var heldRequest: URLRequest?
    /// Called when the page closes the held pop-up while its question is up.
    var onClose: (() -> Void)?
    private(set) var isClosed = false

    static func open(configuration: WKWebViewConfiguration, features: WKWindowFeatures, parent: NSWindow?, opener: Tab?) -> WKWebView {
        let controller = makeController(configuration: configuration, features: features, parent: parent, opener: opener)
        Self.open.insert(controller)
        // Sign-ins and payments run through these; the opener's site helps debugging.
        let opener = WindowManager.shared.controller(for: parent)?.tabManager.selectedTab?.url?.host()
        Diagnostics.note("Pop-up opened", site: opener, isPrivate: controller.isPrivate)
        controller.showWindow(nil)
        if #available(macOS 15.4, *), !controller.isPrivate { ExtensionCenter.popupOpened(controller) }
        return controller.webView
    }

    /// Makes the pop-up window before the answer, so a Mini answer still gives the page a scriptable window
    /// (`window.opener`). Kept off screen with its address held until `revealHeldPage()`; `discardHeldPage()` closes
    /// it without a request.
    static func asking(configuration: WKWebViewConfiguration, features: WKWindowFeatures, parent: NSWindow?, opener: Tab?) -> PopupWindowController {
        let controller = makeController(configuration: configuration, features: features, parent: parent, opener: opener)
        Self.open.insert(controller)
        controller.isHoldingFirstLoad = true
        return controller
    }

    /// Shows the window and loads the held address. Returns false when the window is gone, so the caller can open its
    /// own viewer.
    @discardableResult
    func revealHeldPage() -> Bool {
        guard window != nil, !isClosed else { return false }
        // Route the held address like any page link; a plain webView.load would skip WebKit's block on top-level
        // data: pages.
        if let heldRequest, let url = heldRequest.url,
           case .refuse = PopupNotice.route(url, from: opener?.url) {
            discardHeldPage()
            return false
        }
        isHoldingFirstLoad = false
        showWindow(nil)
        if let heldRequest {
            self.heldRequest = nil
            webView.customUserAgent = SiteUserAgents.agent(for: heldRequest.url)
            webView.load(heldRequest)
        }
        if #available(macOS 15.4, *), !isPrivate { ExtensionCenter.popupOpened(self) }
        return true
    }

    /// Closes the window without fetching the address.
    func discardHeldPage() {
        isHoldingFirstLoad = false
        heldRequest = nil
        onClose = nil
        close()
        // A never-shown window may not report closing, so release it here.
        Self.open.remove(self)
    }

    /// What a reveal is checked against.
    var heldURL: URL? { heldRequest?.url }

    /// Ends the pending question once.
    private func noteClosed() {
        guard !isClosed else { return }
        isClosed = true
        isHoldingFirstLoad = false
        heldRequest = nil
        let close = onClose
        onClose = nil
        close?()
    }

    private static func makeController(configuration: WKWebViewConfiguration, features: WKWindowFeatures,
                                       parent: NSWindow?, opener: Tab?) -> PopupWindowController {
        let size = NSSize(width: features.width.map { CGFloat($0.doubleValue) } ?? Tokens.Metric.popupDefaultSize.width,
                          height: features.height.map { CGFloat($0.doubleValue) } ?? Tokens.Metric.popupDefaultSize.height)
        // A page's screenX and screenY count from the top left of the main display.
        var origin: NSPoint?
        if let x = features.x, let y = features.y, let top = NSScreen.screens.first?.frame.maxY {
            origin = NSPoint(x: CGFloat(x.doubleValue), y: top - CGFloat(y.doubleValue) - size.height)
        }
        return PopupWindowController(configuration: configuration, pageSize: size, origin: origin, parent: parent, opener: opener)
    }

    /// An extension's own small window (`chrome.windows.create({ type: "popup" })`): a volume control, a recorder.
    /// `frame` is where it asked for, in screen coordinates; any part it left out (NaN) is up to Zigzag.
    @available(macOS 15.4, *)
    static func openForExtension(url: URL, configuration: WKWebViewConfiguration, frame: CGRect, parent: NSWindow?) -> PopupWindowController {
        // Chrome's size is the whole window's, its title bar included.
        let size = NSSize(width: frame.width.isFinite && frame.width > 0 ? frame.width : Tokens.Metric.popupDefaultSize.width,
                          height: frame.height.isFinite && frame.height > 0 ? frame.height - headerHeight : Tokens.Metric.popupDefaultSize.height)
        let origin = frame.origin.x.isFinite && frame.origin.y.isFinite ? frame.origin : nil
        let controller = PopupWindowController(configuration: configuration, pageSize: size, origin: origin, parent: parent)
        Self.open.insert(controller)
        controller.webView.load(URLRequest(url: url))
        controller.showWindow(nil)
        ExtensionCenter.popupOpened(controller)
        return controller
    }

    /// Opens `url` in a small viewer window, on the page's data store when given so it stays signed in.
    static func viewer(url: URL, configuration: WKWebViewConfiguration, parent: NSWindow?,
                       by sender: Tab.LoadSender = .page) -> PopupWindowController {
        let controller = PopupWindowController(configuration: configuration,
                                               pageSize: Tokens.Metric.popupDefaultSize, origin: nil, parent: parent)
        controller.openedByRule = sender == .rule
        Self.open.insert(controller)
        controller.webView.customUserAgent = SiteUserAgents.agent(for: url)
        controller.webView.load(URLRequest(url: url))
        controller.showWindow(nil)
        if #available(macOS 15.4, *), !controller.isPrivate { ExtensionCenter.popupOpened(controller) }
        return controller
    }

    /// Set while showing a page a download rule opened, so the rule doesn't catch it again.
    private var openedByRule = false

    private init(configuration: WKWebViewConfiguration, pageSize: NSSize, origin: NSPoint?, parent: NSWindow?, opener: Tab? = nil) {
        // Own preferences, since WebRTC is set per page.
        WebKitSetup.separatePreferences(of: configuration)
        webView = WKWebView(frame: .zero, configuration: configuration)
        self.opener = opener
        openerWebRTCChoices = opener?.webRTCHere ?? [:]
        openerJavaScriptChoices = opener?.javaScriptHere ?? [:]
        let placed = Self.frame(for: NSSize(width: max(320, pageSize.width), height: max(240, pageSize.height) + Self.headerHeight), origin: origin, parent: parent)
        let size = placed.size
        let origin = placed.origin

        let window = PopupWindow(contentRect: NSRect(origin: origin, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        // From a full-screen window, or Zigzag Mini over a full-screen app, it opens over it in the same Space.
        if let parent, parent.styleMask.contains(.fullScreen) || parent.collectionBehavior.contains(.fullScreenAuxiliary) {
            window.collectionBehavior.insert(.fullScreenAuxiliary)
        }
        window.setFrameOrigin(origin)
        window.placeTrafficLights()
        super.init(window: window)
        parentWindow = parent
        window.delegate = self
        // Extensions' shortcuts (1Password's fill) work here too, before the page gets the keys.
        window.commandHandler = { [weak self] event in
            guard #available(macOS 15.4, *), let self, !self.isPrivate,
                  !event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
            return ExtensionCenter.performCommand(for: event)
        }
        // A private window's popup shares its private session: it ends with that window, never outliving it.
        if !configuration.websiteDataStore.isPersistent, let parent {
            parentObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: parent, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.window?.close() }
            }
        }

        let content = ColorView(color: SpaceColor.graphite.background)
        window.contentView = content
        content.addSubview(header)
        // The page gets a holder of its own under the header, so a docked Web Inspector stays under it too.
        let holder = PageHolder(holding: webView)
        content.addSubview(holder)
        header.frame = NSRect(x: 0, y: 0, width: size.width, height: Self.headerHeight)
        header.autoresizingMask = [.width]
        let pin = Tokens.Pane.button, gap = Tokens.Pane.stripGap
        // As far in from the right edge as from the top, with room between the buttons' hover boxes.
        let buttonY = round((Self.headerHeight - pin) / 2)
        openButton.frame = NSRect(x: size.width - buttonY - pin, y: buttonY, width: pin, height: pin)
        copyButton.frame = NSRect(x: openButton.frame.minX - gap - pin, y: buttonY, width: pin, height: pin)
        pinButton.frame = NSRect(x: copyButton.frame.minX - gap - pin, y: buttonY, width: pin, height: pin)
        for button in [pinButton, copyButton, openButton] {
            button.autoresizingMask = [.minXMargin]
            content.addSubview(button)
        }
        header.trailingInset = size.width - pinButton.frame.minX
        copyButton.onClick = { [weak self] _ in self?.copyPageURL(nil) }
        openButton.onClick = { [weak self] _ in self?.openInTab() }
        header.onCopy = { [weak self] in self?.copyPageURL(nil) }
        header.onOpenInTab = { [weak self] in self?.openInTab() }
        pinButton.onClick = { [weak window] _ in
            guard let window else { return }
            KeepOnTop.toggle(window)
        }
        // From a window kept on top, the pop-up is kept on top too, or it would open behind it.
        if let parent, KeepOnTop.isOn(parent) { KeepOnTop.set(true, for: window) }
        KeepOnTop.refresh(pinButton, for: window)
        keepOnTopToken = NotificationCenter.default.addObserver(forName: KeepOnTop.changed, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                KeepOnTop.refresh(self.pinButton, for: self.window)
            }
        }
        // Uses the content view's size, not the requested one: AppKit may round the frame a point taller, and the
        // page must fill to the bottom.
        let area = content.bounds
        holder.frame = NSRect(x: 0, y: Self.headerHeight, width: area.width, height: max(0, area.height - Self.headerHeight))
        holder.autoresizingMask = [.width, .height]
        overlay.frame = holder.frame
        overlay.autoresizingMask = [.width, .height]
        content.addSubview(overlay)
        webView.uiDelegate = self
        webView.navigationDelegate = self
        webView.isInspectable = true

        observations = [
            // A change of address while nothing loads is the page's own (a sign-in moving on with pushState); one
            // still loading waits for the page to arrive (didCommit), so the header never names a site not shown.
            webView.observe(\.url) { [weak self] wv, _ in
                MainActor.assumeIsolated {
                    if !wv.isLoading { self?.shownURL = wv.url; self?.updateHeader() }
                    self?.tellExtensions(.URL)
                }
            },
            webView.observe(\.isLoading) { [weak self] wv, _ in
                MainActor.assumeIsolated {
                    if !wv.isLoading { self?.shownURL = wv.url; self?.updateHeader() }
                    self?.tellExtensions(.loading)
                }
            },
            webView.observe(\.hasOnlySecureContent) { [weak self] _, _ in MainActor.assumeIsolated { self?.updateHeader() } },
            webView.observe(\.title) { [weak self] wv, _ in MainActor.assumeIsolated { self?.window?.title = wv.title ?? ""; self?.tellExtensions(.title) } },
        ]
        updateHeader()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Where the page asked for it, else centered on the window that opened it; always whole on one screen, made
    /// smaller if it's bigger than the screen.
    private static func frame(for size: NSSize, origin: NSPoint?, parent: NSWindow?) -> NSRect {
        var frame = NSRect(origin: .zero, size: size)
        if let origin {
            frame.origin = origin
        } else if let around = parent?.frame ?? NSScreen.main?.visibleFrame {
            frame.origin = NSPoint(x: around.midX - size.width / 2, y: around.midY - size.height / 2)
        }
        let center = NSPoint(x: frame.midX, y: frame.midY)
        guard let area = (NSScreen.screens.first { $0.frame.contains(center) } ?? parent?.screen ?? NSScreen.main)?.visibleFrame else {
            return frame
        }
        frame.size = NSSize(width: min(frame.width, area.width), height: min(frame.height, area.height))
        frame.origin.x = min(max(frame.minX, area.minX), area.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, area.minY), area.maxY - frame.height)
        return frame
    }

    private func tellExtensions(_ change: WKWebExtension.TabChangedProperties) {
        guard #available(macOS 15.4, *), !isPrivate, Self.open.contains(self) else { return }
        ExtensionCenter.popupChanged(self, change)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if #available(macOS 15.4, *), !isPrivate { ExtensionCenter.popupFocused(self) }
    }

    /// The address of the page on screen: never one only on its way, which a page could start and never finish.
    private var shownURL: URL?

    /// The address the error page is showing, if any.
    private var errorShownFor: URL?
    private let downloads = DownloadPolicy()

    /// Matches Site Controls: a certificate let through, or Zigzag's own warning page, is never secure.
    private func updateHeader() {
        let connection = SitePanel.connection(scheme: shownURL?.scheme, onlySecureContent: webView.hasOnlySecureContent,
                                              certificateException: CertificateExceptions.isShowingException(in: webView),
                                              hasCertificate: !(shownURL != nil && shownURL == errorShownFor))
        header.show(url: shownURL, secure: !connection.warns)
        copyButton.isEnabled = Self.movableURL(shownURL) != nil
        openButton.isEnabled = canOpenInTab
    }

    // MARK: Its page, as a tab's

    /// An address a tab can open: none for a blank page or an extension's own.
    static func movableURL(_ url: URL?) -> URL? {
        guard let url, let scheme = url.scheme?.lowercased(), ["http", "https", "file"].contains(scheme) else { return nil }
        return url
    }

    /// The profile whose sign-ins the page has; nil for a private page or one in no profile's store.
    private var profile: Profile? { isPrivate ? nil : Profiles.shared.profile(ofStore: webView.configuration.websiteDataStore) }

    /// Whether the page can move into a tab and keep its sign-in: a web or file address, in a private window's store
    /// or a profile's. One in a store no tab has would sign in afresh, so it stays a pop-up.
    var canOpenInTab: Bool { Self.movableURL(shownURL) != nil && (isPrivate || profile != nil) }

    /// Reopens the page as a tab in the opener's window, in a space of the page's own profile, then closes the popup
    /// (WebKit can't move a live page). Never in another profile's space, where its sign-in isn't.
    func openInTab() {
        guard let url = Self.movableURL(shownURL ?? webView.url), !isClosed else { return }
        let manager = WindowManager.shared
        let store = webView.configuration.websiteDataStore
        let target: BrowserWindowController
        var space: UUID?
        if isPrivate {
            // The private window whose store it shares keeps its sign-in.
            target = manager.controllers.first { $0.tabManager.privateStore === store }
                ?? manager.newWindow(showCommandBar: false, isPrivate: true)
        } else {
            guard let profile else { return }
            target = manager.controller(for: parentWindow).flatMap { $0.tabManager.isPrivate ? nil : $0 } ?? MiniWindowController.browserWindow()
            let openerSpace = opener.flatMap { tab in target.tabManager.allTabs.contains { $0 === tab } ? tab.spaceID : nil }
            space = Self.space(for: profile.id, opener: openerSpace, manager: target.tabManager)
        }
        let inTarget = opener.flatMap { tab in target.tabManager.allTabs.contains { $0 === tab } && tab.spaceID == space ? tab : nil }
        if let space { target.tabManager.switchToSpace(space) }
        target.tabManager.newTab(url: url, spaceID: space, opener: inTarget, by: .you)
        window?.close()
        target.window?.makeKeyAndOrderFront(nil)
    }

    /// Where a page of `profile` opens as a tab: the opener's space when it's on that profile, else one of that
    /// profile's, else a new space on it.
    static func space(for profile: UUID, opener: UUID?, manager: TabManager) -> UUID {
        let library = Library.shared
        if let opener, library.space(opener) != nil, library.profileID(ofSpace: opener) == profile { return opener }
        if library.profileID(ofSpace: manager.currentSpaceID) == profile { return manager.currentSpaceID }
        let spaces = library.spaces(in: profile).map(\.id)
        if let space = spaces.first(where: { !manager.tabs(in: $0).isEmpty }) ?? spaces.first { return space }
        return library.addSpace(profile: profile).id
    }

    /// ⌘O with the popup in front, as in Zigzag Mini: Open in New Tab.
    @objc func openDocument(_ sender: Any?) { openInTab() }

    /// The strip's Copy Link, ⇧⌘C, and the address's right-click menu.
    @objc func copyPageURL(_ sender: Any?) {
        // A web or file address, as Copy Link in the strip and its right-click menu; never a blank or extension page's.
        guard let url = Self.movableURL(shownURL) else { return }
        CleanLink.write(url, title: webView.title)
        Toast.show(String(localized: "Link copied", comment: "Toast after the page's address is copied."), symbol: "link", over: overlay, area: overlay.bounds)
    }

    /// ⌘W: the popup holds one page, so the window closes.
    @objc func closeTab(_ sender: Any?) { window?.performClose(sender) }
    @objc func goBack(_ sender: Any?) { webView.goBack() }
    @objc func goForward(_ sender: Any?) { webView.goForward() }
    @objc func reloadPage(_ sender: Any?) { webView.reload() }
    @objc func reloadPageFromOrigin(_ sender: Any?) { webView.reloadFromOrigin() }
    @objc func stopLoading(_ sender: Any?) { webView.stopLoading() }

    @objc func showFindBar(_ sender: Any?) { findBar.toggle() }
    @objc func findNextMatch(_ sender: Any?) { findBar.next(backwards: false) }
    @objc func findPreviousMatch(_ sender: Any?) { findBar.next(backwards: true) }
    @objc func useSelectionForFind(_ sender: Any?) {
        webView.runOwnScript("window.getSelection().toString()") { [weak self] answer in
            let result = try? answer.get()
            MainActor.assumeIsolated {
                guard let text = result as? String, !text.isEmpty else { return }
                self?.findBar.show(query: text)
            }
        }
    }

    @objc func zoomIn(_ sender: Any?) { setZoom(ZoomLevels.step(webView.pageZoom, by: 1)) }
    @objc func zoomOut(_ sender: Any?) { setZoom(ZoomLevels.step(webView.pageZoom, by: -1)) }
    @objc func actualSize(_ sender: Any?) {
        setZoom(ZoomLevels.defaultZoom)
        webView.magnification = 1
    }

    /// As in a tab: kept for the site, except in private.
    private func setZoom(_ zoom: CGFloat) {
        webView.pageZoom = zoom
        if !isPrivate, let url = shownURL { ZoomLevels.set(zoom, for: url) }
        Toast.show(ZoomLevels.percent(zoom), symbol: zoom < 1 ? "minus.magnifyingglass" : zoom > 1 ? "plus.magnifyingglass" : "magnifyingglass",
                   over: overlay, area: overlay.bounds)
    }

    private var inspector: NSObject? {
        let selector = NSSelectorFromString("_inspector")
        guard webView.responds(to: selector) else { return nil }
        return webView.perform(selector)?.takeUnretainedValue() as? NSObject
    }

    @objc func showWebInspector(_ sender: Any?) {
        guard let inspector else { return }
        inspector.callIfPresent(inspector.inspectorFlag("isVisible") ? "close" : "show")
    }

    @objc func showJavaScriptConsole(_ sender: Any?) { inspector?.callIfPresent("showConsole") }

    @objc func inspectElement(_ sender: Any?) {
        guard let inspector else { return }
        if !inspector.inspectorFlag("isVisible") { inspector.callIfPresent("show") }
        inspector.callIfPresent("toggleElementSelection")
    }

    /// Shows an extension's popup over this window, from the right end of its header, so it isn't hidden behind it.
    func showExtensionPopover(_ popover: NSPopover) {
        window?.makeKeyAndOrderFront(nil)
        let spot = NSRect(x: header.bounds.maxX - Tokens.Space.x8, y: 0, width: Tokens.Space.x4, height: header.bounds.height)
        popover.behavior = .semitransient
        popover.show(relativeTo: spot, of: header, preferredEdge: .maxY)
    }

    func windowWillClose(_ notification: Notification) {
        madeFindBar?.hide()
        noteClosed()
        observations.forEach { $0.invalidate() }
        webView.stopLoading()
        if let parentObserver { NotificationCenter.default.removeObserver(parentObserver) }
        parentObserver = nil
        keepOnTopToken.map(NotificationCenter.default.removeObserver)
        keepOnTopToken = nil
        if #available(macOS 15.4, *), !isPrivate, Self.open.contains(self) { ExtensionCenter.popupClosed(self) }
        Self.open.remove(self)
    }

    func webViewDidClose(_ webView: WKWebView) {
        Diagnostics.note("Pop-up closed itself", site: webView.url?.host(), isPrivate: isPrivate)
        noteClosed()
        window?.close()
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard Tab.mayOpenInNewWebView(navigationAction.request.url) else { return nil }
        // Unclicked pop-ups open only via a kept destination, or ask.
        if !PopupNotice.isClicked(navigationAction, in: webView, isPrivate: isPrivate) {
            // Any kind of window: a page in Zigzag Mini or an installed app also asks there. Looking up only browser
            // windows dropped those pop-ups silently.
            let parent = WindowManager.shared.promptHost(for: parentWindow) ?? (opener?.host as? PromptHost)
            // A blank window.open() counts as a page link so allowed sites can open-then-navigate. WebKit passes it
            // as a scheme-less address, not nil.
            let (target, isBlank) = PopupNotice.popupTarget(navigationAction.request.url)
            // Same routing as page links: app addresses ask their own question; anything not allowed top-level opens
            // nowhere.
            switch PopupNotice.route(target, from: webView.url) {
            case .refuse:
                Diagnostics.note("Refused a page's pop-up", site: webView.url?.host(), "\(target.scheme ?? "no scheme"):", isPrivate: isPrivate)
                return nil
            case .app:
                // Only the main frame asks for an app; a frame's pop-up stays blocked.
                guard navigationAction.sourceFrame.isMainFrame else {
                    Diagnostics.note("Blocked a frame's pop-up", site: webView.url?.host(),
                                     "\(target.scheme ?? "no scheme"):", isPrivate: isPrivate)
                    return nil
                }
                opener?.openFromPage(target, isClick: false, asker: navigationAction.sourceFrame.securityOrigin)
                return nil
            case .open:
                break
            }
            // A kept destination applies to frames and blank pop-ups too, but only Allow and Mini: This Tab or New
            // Tab from those would move the page without a click.
            var automatic = false
            if !isPrivate, let stored = PopupNotice.storedAction(origin: SiteOrigin.of(webView.url)) {
                let destination = PopupNotice.destination(for: stored)
                guard PopupNotice.storedDestinationMayOpen(destination, forBlankOrFrame: isBlank || !navigationAction.sourceFrame.isMainFrame) else {
                    return nil
                }
                switch destination {
                case .deny:
                    return nil
                case .viewer:
                    return PopupWindowController.open(configuration: configuration, features: windowFeatures, parent: window, opener: opener)
                case .thisTab, .newTab:
                    if let parent {
                        PopupNotice.open(target, action: stored, from: opener, in: parent, configuration: configuration)
                    }
                    return nil
                case .automatic:
                    // Legacy allow: normal routing, as for a click.
                    automatic = true
                }
            }
            guard automatic else {
                // Only the main frame asks, and a blank address with no allowed site has nothing to ask about.
                guard !isBlank, navigationAction.sourceFrame.isMainFrame else {
                    Diagnostics.note("Blocked a frame's or a blank pop-up", site: webView.url?.host(),
                                     "\(target.scheme ?? "no scheme"):", isPrivate: isPrivate)
                    return nil
                }
                // Ask in the opener tab's window, brought forward so the card isn't behind the pop-up.
                parent?.window?.makeKeyAndOrderFront(nil)
                return PopupNotice.ask(navigationAction, from: webView.url, isPrivate: isPrivate, tab: opener, in: parent,
                                       configuration: configuration, features: windowFeatures)
            }
        }
        // A plain link (a help page, the terms) opens as a tab in the browser window, brought forward, as a
        // browser would; only another sized window.open() is a popup of its own.
        let sized = windowFeatures.width != nil || windowFeatures.height != nil || windowFeatures.toolbarsVisibility?.boolValue == false
        if !sized, let controller = WindowManager.shared.controller(for: parentWindow) {
            let tab = controller.tabManager.newTab(url: nil, configuration: configuration, site: navigationAction.request.url)
            controller.window?.makeKeyAndOrderFront(nil)
            return tab.ensureWebView()
        }
        return PopupWindowController.open(configuration: configuration, features: windowFeatures, parent: window, opener: opener)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {
        await PageDialogs.alert(message: message, frame: frame, window: window)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
        await PageDialogs.confirm(message: message, frame: frame, window: window)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo) async -> String? {
        await PageDialogs.prompt(message: prompt, defaultText: defaultText, frame: frame, window: window)
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        await PageDialogs.openPanel(parameters: parameters, window: window)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        let policy = await decide(navigationAction, in: webView)
        // Scripts as in a tab (`SiteJavaScript`), with the opener's private choices.
        if policy == .allow {
            let mainFrame = navigationAction.targetFrame?.isMainFrame ?? true
            SiteJavaScript.apply(to: preferences, for: mainFrame ? navigationAction.request.url : webView.url, here: javaScriptChoices,
                                 errorPage: mainFrame && ErrorPage.pending.contains(webView))
        }
        return (policy, preferences)
    }

    private func decide(_ navigationAction: WKNavigationAction, in webView: WKWebView) async -> WKNavigationActionPolicy {
        // Hold the address while waiting: WebKit loads into the view before the answer, and a denied pop-up must not
        // have requested its page.
        if isHoldingFirstLoad {
            // First main-frame address only; a later `window.open('/a.html')` redirect can't change what's revealed.
            if heldRequest == nil, navigationAction.targetFrame?.isMainFrame ?? true {
                heldRequest = navigationAction.request
            }
            return .cancel
        }
        // Unclicked download streams are refused, as in a tab.
        let clicked = PopupNotice.isUserInitiated(navigationAction)
        if let policy = downloads.decide(shouldDownload: navigationAction.shouldPerformDownload, clicked: clicked,
                                         isMainFrame: navigationAction.targetFrame?.isMainFrame ?? true) {
            // A download rule may take it; then WebKit makes no download.
            if policy == .download, let url = navigationAction.request.url,
               await handOffIfWanted(url, request: navigationAction.request, appliesToLinks: false,
                                      wasClicked: clicked) { return .cancel }
            // Otherwise ask once per site whether it may download. Page-started downloads never ask, but a kept
            // answer still applies.
            if policy == .download, let url = navigationAction.request.url,
               await !mayDownload(url, request: navigationAction.request, asking: clicked) { return .cancel }
            if policy == .cancel {
                // Page-started: Allow Once re-requests from the same page; a request that can't be re-sent leaves the
                // notice as it is.
                let origin = SiteOrigin.of(webView.url) ?? SiteOrigin.of(navigationAction.request.url)
                refusedDownload(action: origin.flatMap {
                    askAgain(origin: $0, request: navigationAction.request, keepAnswer: false)
                })
            }
            return policy
        }
        // A rule's link opens in its app, not a blank pop-up page.
        if PopupNotice.isUserInitiated(navigationAction), let url = navigationAction.request.url,
           await handOffIfWanted(url, request: navigationAction.request, appliesToLinks: true, wasClicked: true) { return .cancel }
        // Zigzag's own pages (History) open in its tabs, never in a page's pop-up.
        if navigationAction.request.url?.scheme?.lowercased() == HistoryPage.scheme { return .cancel }
        // Chrome's address for a page of the extension showing here goes to Zigzag's own for it (Tab.extensionPageAddress).
        if let url = navigationAction.request.url, url.scheme?.lowercased() == "chrome-extension" {
            let page = Tab.extensionPageAddress(url)
            let source = navigationAction.sourceFrame.securityOrigin
            if navigationAction.targetFrame?.isMainFrame ?? true, source.protocol == "webkit-extension", source.host.lowercased() == page.host() {
                DispatchQueue.main.async { [weak webView] in webView?.load(URLRequest(url: page)) }
            }
            return .cancel
        }
        // Set WebRTC for the destination before its page is made, as in a tab.
        if navigationAction.targetFrame?.isMainFrame == true, let url = navigationAction.request.url, !ExternalLinks.isExternal(url) {
            WebRTCProtection.apply(to: webView, for: url, here: webRTCChoices)
            // The site's user agent, as in a tab (#392): a request made as another browser is made again.
            let wanted = SiteUserAgents.agent(for: url)
            let again = Tab.asksAgain(sent: webView.customUserAgent, wanted: wanted, isGet: (navigationAction.request.httpMethod ?? "GET") == "GET",
                                      type: navigationAction.navigationType)
            if (webView.customUserAgent ?? "") != (wanted ?? "") { webView.customUserAgent = wanted }
            if again {
                let request = navigationAction.request
                DispatchQueue.main.async { [weak webView] in webView?.load(request) }
                return .cancel
            }
        }
        if let url = navigationAction.request.url, ExternalLinks.isExternal(url), url.scheme?.lowercased() != "file" {
            ExternalLinks.open(url, isMainFrame: navigationAction.targetFrame?.isMainFrame ?? true,
                               isClick: PopupNotice.isUserInitiated(navigationAction),
                               linkClick: navigationAction.navigationType == .linkActivated, sourceIsMainFrame: navigationAction.sourceFrame.isMainFrame, from: webView,
                               asker: navigationAction.sourceFrame.securityOrigin)
            return .cancel
        }
        return .allow
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        openedByRule = false
        // A click on the page before doesn't let this one open a pop-up.
        PopupNotice.forgetInput(in: webView)
        PageDialogs.pageLoaded(webView)
        shownURL = webView.url
        errorShownFor = ErrorPage.consume(webView) ? webView.url : nil
        updateHeader()
    }

    /// A page that never arrived says why, as a tab does, rather than leave the window blank.
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        openedByRule = false
        // It never came: the header stays on the page still showing.
        shownURL = webView.url
        updateHeader()
        let nsError = error as NSError
        if nsError.code == NSURLErrorCancelled || (nsError.domain == "WebKitErrorDomain" && [102, 204].contains(nsError.code)) { return }
        let failingURL = (nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? webView.url
        Diagnostics.note("Pop-up didn’t load", site: failingURL?.host(), Diagnostics.describe(nsError), isPrivate: isPrivate)
        ErrorPage.show(error: nsError, url: failingURL, in: webView)
    }

    /// The page's process crashed: load it again rather than leave a blank window, unless it just did the same.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        let again = lastCrash.map { Date().timeIntervalSince($0) < 10 } ?? false
        Diagnostics.note("Pop-up page stopped", site: webView.url?.host(), isPrivate: isPrivate)
        lastCrash = Date()
        guard !again else { return }
        if webView.url != nil { webView.reload() }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        let response = navigationResponse.response
        StrictTransport.note(response, in: webView.configuration.websiteDataStore)
        // As in a tab: an attachment is saved, never shown as the page.
        let policy = downloads.decide(mimeType: response.mimeType, contentDisposition: (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition"),
                                      canShowMIMEType: navigationResponse.canShowMIMEType, isMainFrame: navigationResponse.isForMainFrame)
        if policy == .download, let url = response.url {
            let mime = (response.mimeType ?? "").lowercased()
            let disposition = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition") ?? ""
            let filename = DownloadTokens.filename(for: url, suggested: Tab.filename(from: disposition) ?? "")
            let wasClicked = downloads.mainFrameWasClicked && navigationResponse.isForMainFrame
            if await handOffIfWanted(url, request: URLRequest(url: url), appliesToLinks: false, filename: filename, mime: mime,
                                     wasClicked: wasClicked) {
                return .cancel
            }
            // Then the site's download permission decides. Unclicked responses never ask.
            if await !mayDownload(url, asking: wasClicked) { return .cancel }
        }
        if policy == .cancel, navigationResponse.isForMainFrame { refusedDownload() }
        // WebRTC follows a redirect's destination.
        if navigationResponse.isForMainFrame {
            WebRTCProtection.apply(to: webView, for: policy == .allow ? response.url : webView.url, here: webRTCChoices)
        }
        return policy
    }

    /// Shown under the header, never silently.
    private func refusedDownload(text: String = DownloadPolicy.refusedText, note: String = "A page started another download without a click",
                                 action: (title: String, run: () -> Void)? = nil) {
        Diagnostics.note("Download refused", site: webView.url?.host(), note, isPrivate: isPrivate)
        guard let content = window?.contentView, window?.isVisible == true else { return }
        let area = NSRect(x: 0, y: Self.headerHeight, width: content.bounds.width, height: max(0, content.bounds.height - Self.headerHeight))
        // Longer when there's an action, and dismissable, as in a tab.
        Toast.show(text, symbol: "arrow.down.circle", action: action, duration: action == nil ? 3 : 6,
                   closes: action != nil, over: content, area: area)
    }

    /// As in a tab: WebKit's refusal can't be undone, so Allow Once re-requests through this page (keeping its
    /// session) and keeps the answer for the page. Only plain GETs can be re-sent.
    private func askAgain(origin: String, request: URLRequest?,
                          keepAnswer: Bool = true) -> (title: String, run: () -> Void)? {
        guard let request, DownloadPolicy.canBeAskedAgain(request) else { return nil }
        return (String(localized: "Allow Once", comment: "Button in the notice saying a site’s download was blocked: asks the site for the file again and saves it."),
                { [weak webView, opener] in
                    guard let webView else { return }
                    // Page-only, and only when the site question was what refused it; a site Block still wins.
                    if keepAnswer { SitePermissions.allowThisDownload(origin: origin, tab: opener) }
                    webView.startDownload(using: request) { download in
                        DownloadManager.shared.track(download, window: webView.window)
                    }
                })
    }

    /// As in a tab: asked once, "This time" for the page, "Always" for the site. False means cancel the download.
    private func mayDownload(_ url: URL, request: URLRequest? = nil, asking: Bool = true) async -> Bool {
        guard let origin = SiteOrigin.of(webView.url ?? url) else {
            // Local files have no site. A site-made page (about:blank, data:) has no nameable origin, so with asking
            // on it can't download.
            if SitePermissions.pageWithoutSiteMayDownload(isFile: (webView.url ?? url).isFileURL) { return true }
            refusedDownload(text: DownloadPolicy.blockedText, note: "A page with no site of its own tried to save a file")
            return false
        }
        // The parent may be another pop-up, which can't ask; the opener tab's window asks and comes forward.
        let window = WindowManager.shared.promptHost(for: parentWindow)?.window
            ?? opener.flatMap { WindowManager.shared.promptHost(holding: $0)?.window }
        // Bring the window forward only when the site still needs asking. With no window, a site that needs asking is
        // refused below.
        if let window, SitePermissions.asksBeforeDownloads, SitePermissions.downloads(origin: origin, tab: opener) == nil {
            window.makeKeyAndOrderFront(nil)
        }
        let allowed = await SitePermissions.downloadsAllowed(origin: origin, window: window, isPrivate: isPrivate, tab: opener,
                                                             asking: asking)
        if !allowed {
            refusedDownload(text: DownloadPolicy.blockedText, note: "This site is not allowed to save files",
                            action: askAgain(origin: origin, request: request))
        }
        return allowed
    }

    /// True when a rule took `url`, so the pop-up shouldn't load or download it.
    private func handOffIfWanted(_ url: URL, request: URLRequest, appliesToLinks: Bool, filename: String? = nil,
                                 mime: String = "", wasClicked: Bool = false) async -> Bool {
        // Don't re-catch a page a rule opened here.
        guard !openedByRule else { return false }
        // Zigzag's own pages and extension pages are never handed off.
        guard url.scheme?.lowercased() != HistoryPage.scheme, !Tab.isExtensionPage(url) else { return false }
        // File-type rules match a download's name; links have none.
        let handoffName = appliesToLinks ? "" : (filename ?? DownloadTokens.filename(for: url, suggested: ""))
        guard let rule = DownloadHandoff.firstMatch(url, appliesToLinks: appliesToLinks, filename: handoffName,
                                                    isPrivate: isPrivate) else { return false }
        let referrer = request.value(forHTTPHeaderField: "Referer").flatMap { URL(string: $0) } ?? webView.url
        let handoff = DownloadHandoff.Request(url: url, referrer: referrer, pageOrigin: SiteOrigin.of(webView.url),
                                              filename: filename ?? DownloadTokens.filename(for: url, suggested: ""),
                                              mime: mime, space: "",
                                              dataStore: webView.configuration.websiteDataStore, isPrivate: isPrivate,
                                              window: parentWindow, tab: nil, wasClicked: wasClicked, mayAsk: false)
        // Pop-ups have no page store for an answer (the opener's is another page's). Until the card supports pop-up
        // hosts, they never ask.
        let decision = await DownloadHandoff.decide(rule, request: handoff, tab: nil, forDownload: !appliesToLinks)
        switch decision.gate {
        case .handOff:
            let outcome = await DownloadHandoff.perform(rule, request: handoff)
            if case .failed = outcome { DownloadHandoff.report(outcome, rule: rule, request: handoff) }
            if case .noMatch = outcome { return false }
            return true
        case .browser:
            return false
        case .cancel:
            // Don't Allow: a link goes nowhere and a download isn't saved.
            return true
        }
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        DownloadManager.shared.track(download, window: window)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        DownloadManager.shared.track(download, window: window)
    }

    @objc(_webView:contextMenuDidCreateDownload:)
    func webView(_ webView: WKWebView, contextMenuDidCreate download: WKDownload) {
        DownloadManager.shared.track(download, window: window)
    }

    /// The page's own Print button (`window.print()`), as in a tab (`PagePrinting`).
    @objc(_webView:printFrame:pdfFirstPageSize:completionHandler:)
    func webView(_ webView: WKWebView, printFrame frame: AnyObject?, pdfFirstPageSize size: CGSize, completionHandler: @escaping () -> Void) {
        PagePrinting.printForPage(webView, frame: frame, in: window, completion: completionHandler)
    }

    @objc(_webView:printFrame:)
    func webView(_ webView: WKWebView, printFrame frame: AnyObject?) {
        PagePrinting.printForPage(webView, frame: frame, in: window, completion: {})
    }

    /// File › Print… (⌘P) with the popup in front.
    @objc func printPage(_ sender: Any?) {
        PagePrinting.print(webView, in: window, completion: {})
    }

    /// The window the page is told it's in, as a tab's page is (PageWindowFrame).
    @objc(_webView:getWindowFrameWithCompletionHandler:)
    func webView(_ webView: WKWebView, getWindowFrameWithCompletionHandler completion: @escaping (CGRect) -> Void) {
        completion(PageWindowFrame.frame(of: webView, hostWindow: window))
    }

    func webView(_ webView: WKWebView, respondTo challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        await AuthenticationPrompt.respond(to: challenge, window: window, store: webView.configuration.websiteDataStore, page: webView, tab: isPrivate ? nil : tab)
    }
}

#if DEBUG
extension PopupWindowController {
    var debugState: [String: Any] {
        ["url": shownURL?.absoluteString ?? "-", "copy": copyButton.isEnabled, "open": openButton.isEnabled,
         "selected": (window?.firstResponder as? NSTextView)?.string ?? ""]
    }
    func debugSelectAddress() { header.selectAddress() }
}
#endif

extension PopupWindowController: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        // ⌘← and ⌘→ (the hidden Back and Forward) in a text field or the page move the cursor, as in a browser window.
        if item.isHidden, item.action == #selector(goBack(_:)) || item.action == #selector(goForward(_:)),
           window?.firstResponder is NSText || window?.firstResponder is WKWebView {
            return false
        }
        switch item.action {
        case #selector(openDocument(_:)):
            item.title = Self.openInTabTitle
            return canOpenInTab
        case #selector(copyPageURL(_:)): return Self.movableURL(shownURL) != nil
        case #selector(goBack(_:)): return webView.canGoBack
        case #selector(goForward(_:)): return webView.canGoForward
        case #selector(stopLoading(_:)): return webView.isLoading
        case #selector(findNextMatch(_:)), #selector(findPreviousMatch(_:)): return madeFindBar?.hasQuery == true
        default: return true
        }
    }
}

extension PopupWindowController: FindBarHost {
    var focusedPaneFrame: NSRect { overlay.bounds }
    var findBarHeaderHeight: CGFloat { 0 }
    var findBarOverlay: NSView { overlay }
    var findBarIsCovered: Bool { false }
    var findableWebView: WKWebView? { webView }
    var findablePDF: PDFViewerView? { nil }
}

/// Gives extension shortcuts the keys first, like the browser window, and keeps the traffic lights centered on the
/// header.
private final class PopupWindow: NSWindow {
    var commandHandler: ((NSEvent) -> Bool)?
    private var buttonSpacing: CGFloat?

    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        // AppKit resets the buttons on every title bar layout.
        TrafficLightKeeper.install(in: self) { [weak self] in self?.placeTrafficLights() }
    }

    /// Fingers skip `sendEvent`; the whole frame is watched for them (`TouchPress`).
    override var contentView: NSView? {
        didSet { TouchPress.watch(self) }
    }

    /// Centered on the header, same left inset as the browser window.
    func placeTrafficLights() {
        guard !styleMask.contains(.fullScreen), let close = standardWindowButton(.closeButton) else { return }
        let origin = NSPoint(x: Tokens.Sidebar.lightsX, y: round((PopupWindowController.headerHeight - close.frame.height) / 2))
        buttonSpacing = placeTrafficLights(at: origin, spacing: buttonSpacing)
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, commandHandler?(event) == true { return }
        super.sendEvent(event)
    }
}

/// Traffic lights on the left, the full address in the middle (`FullAddress`), or just the site when narrow.
final class PopupHeaderView: NSView {
    private let label = Label("", font: Tokens.Font.body(.medium), color: Tokens.Color.textPrimary)
    private var fullAddress: FullAddress.Parts?
    private let lock = NSImageView()
    /// Room kept clear at the right end for buttons laid over the strip (Zigzag Mini's Open in Zigzag).
    var trailingInset: CGFloat = 0 { didSet { needsLayout = true } }
    /// The address's right-click menu.
    var onCopy: (() -> Void)?
    var onOpenInTab: (() -> Void)?
    /// The whole address, selectable to copy, while the address is clicked.
    private var shownURL: URL?
    private var shownSecure = true
    private let hit = AddressHit()
    private var selectable: SelectableAddress?
    /// The address field the selected address sits in: the one the command bar shows over a strip's address.
    private var selectableBox: FloatingPanelView?

    override init(frame: NSRect) {
        super.init(frame: frame)
        lock.imageScaling = .scaleNone
        lock.contentTintColor = Tokens.Color.textSecondary
        addSubview(lock)
        // A long host loses its start, never its end, which says whose site it is.
        label.lineBreakMode = .byTruncatingHead
        addSubview(label)
        hit.onClick = { [weak self] in self?.selectAddress() }
        addSubview(hit)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    func show(url: URL?, secure: Bool) {
        if url != shownURL { endSelecting() }
        shownURL = url
        shownSecure = secure
        // An extension's own page: whose it is, not an address no one could read.
        fullAddress = nil
        if #available(macOS 15.4, *), let ext = ExtensionCenter.webExtension(ofPage: url) {
            label.stringValue = ext.displayName ?? ""
            lock.image = Tokens.Symbol.image("puzzlepiece.extension", size: Tokens.Symbol.inline)
            lock.isHidden = false
            lock.setAccessibilityLabel(String(localized: "Extension", comment: "VoiceOver label of the icon before an extension's address in a pop-up window."))
            needsLayout = true
            return
        }
        // No site at all (data:): said so, and no lock, which would vouch for a site that isn't there.
        let site = Self.site(of: url)
        label.stringValue = site ?? AddressView.name(of: url)
        fullAddress = site == nil ? nil : FullAddress.parts(of: url)
        lock.isHidden = site == nil
        // Same not-secure padlock as the address bar and Site Controls.
        lock.image = Tokens.Symbol.image(secure ? "lock" : SitePanel.notSecureSymbol, size: Tokens.Symbol.inline)
        lock.setAccessibilityLabel(secure ? String(localized: "Secure connection", comment: "VoiceOver label of the lock before the address in a pop-up window.")
                                           : SitePanel.notSecure)
        needsLayout = true
    }

    /// The site a page's address names, with its port when it isn't the usual one, so "accounts.google.com:81"
    /// never reads as Google's own. A blob: page is named for the site whose script made it, as the address names
    /// it. Nil when there's no site (data:, about:blank).
    static func site(of url: URL?) -> String? {
        guard let url else { return nil }
        let site = url.scheme?.lowercased() == "blob" ? URL(string: String(url.absoluteString.dropFirst("blob:".count))) : url
        guard let site, site.scheme?.lowercased() != "blob", let host = site.host(), !host.isEmpty else { return nil }
        let usual = site.scheme == "https" ? 443 : site.scheme == "http" ? 80 : nil
        return host + (site.port.flatMap { $0 == usual ? nil : ":\($0)" } ?? "")
    }

    override func layout() {
        super.layout()
        // Without its lock, the name alone is centered.
        let lockWidth = lock.isHidden ? 0 : Tokens.Space.x3
        let gap = lock.isHidden ? 0 : Tokens.Space.x1
        let leading = Tokens.Space.x16 + Tokens.Space.x4
        var textWidth = label.textWidth
        if let fullAddress {
            // Full address if it fits; truncated at the end if the site and some path fit; else the site alone.
            let font = label.font ?? Tokens.Font.body(.medium)
            func measure(_ text: String) -> CGFloat { ceil((text as NSString).size(withAttributes: [.font: font]).width) }
            let most = max(0, bounds.width - leading - lockWidth - gap - Tokens.Space.x4 - trailingInset)
            let pad = Tokens.Space.x2
            textWidth = FullAddress.shown(fullAddress, room: most - pad, measure: measure) == .host ? measure(fullAddress.host) + pad
                : min(measure(fullAddress.whole) + pad, most)
        }
        let textSize = NSSize(width: textWidth, height: label.lineHeight)
        let total = lockWidth + gap + ceil(textSize.width)
        let x = max(leading, (bounds.width - total) / 2)
        let h = ceil(textSize.height)
        lock.frame = NSRect(x: x, y: 0, width: lockWidth, height: bounds.height)
        label.frame = NSRect(x: lock.frame.maxX + gap, y: (bounds.height - h) / 2, width: max(0, min(ceil(textSize.width), bounds.width - x - Tokens.Space.x4 - trailingInset)), height: h)
        if let fullAddress { FullAddress.show(fullAddress, in: label, room: label.frame.width - Label.inset * 2) }
        hit.frame = label.frame.insetBy(dx: -Tokens.Space.x1, dy: 0)
        hit.frame.origin.y = 0
        hit.frame.size.height = bounds.height
        hit.isHidden = PopupWindowController.movableURL(shownURL) == nil
        layoutSelectable()
    }

    private func layoutSelectable() {
        guard let box = selectableBox, let field = selectable else { return }
        let h = Tokens.Pane.addressHeight
        box.frame = NSRect(x: selectableFrame.minX, y: round((bounds.height - h) / 2), width: selectableFrame.width, height: h)
        // The command bar's own insets in a strip's field (`CommandBarController.layoutPanel`).
        let inset = field.textInset, x = Tokens.Space.x3 - 4
        let textHeight = ceil(field.intrinsicContentSize.height)
        field.frame = NSRect(x: x - inset, y: field.centeredY(in: h) - inset * 2, width: max(0, box.bounds.width - x - Tokens.Space.x3) + inset * 2, height: textHeight + inset * 4)
    }

    /// The room the whole address takes while selected: the strip between the traffic lights and the buttons.
    private var selectableFrame: NSRect {
        let leading = Tokens.Space.x16 + Tokens.Space.x4
        let h = ceil(label.lineHeight)
        return NSRect(x: leading, y: round((bounds.height - h) / 2), width: max(0, bounds.width - leading - Tokens.Space.x2 - trailingInset), height: h)
    }

    /// Shows the whole address selected, read-only, until Esc or focus moves on.
    func selectAddress() {
        guard let url = PopupWindowController.movableURL(shownURL), selectable == nil else { return }
        let field = SelectableAddress(font: Tokens.Font.voice(Tokens.Pane.addressText), placeholder: "")
        field.stringValue = url.absoluteString
        field.isEditable = false
        field.isSelectable = true
        field.textInset = 2
        field.centersText = true
        field.onEnd = { [weak self] in self?.endSelecting() }
        field.setAccessibilityLabel(String(localized: "Address", comment: "VoiceOver label of a pop-up window's address while it's selected to copy."))
        let box = FloatingPanelView()
        box.radius = Tokens.Radius.control
        box.addSubview(field)
        addSubview(box)
        selectableBox = box
        selectable = field
        layoutSelectable()
        [label, lock, hit].forEach { $0.isHidden = true }
        window?.makeFirstResponder(field)
        field.selectText(nil)
        if let editor = field.currentEditor() as? NSTextView {
            let accent = Brand.Theme.of(nil).accent
            editor.insertionPointColor = accent
            editor.selectedTextAttributes = [.backgroundColor: accent.withAlphaComponent(Tokens.Color.textSelectionAlpha)]
        }
    }

    private func endSelecting() {
        guard let field = selectable else { return }
        selectable = nil
        field.onEnd = nil
        if field.currentEditor() != nil { window?.makeFirstResponder(nil) }
        selectableBox?.removeFromSuperview()
        selectableBox = nil
        label.isHidden = false
        hit.isHidden = false
        show(url: shownURL, secure: shownSecure)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard PopupWindowController.movableURL(shownURL) != nil else { return nil }
        let menu = NSMenu()
        let copy = NSMenuItem(title: PopupWindowController.copyLinkTitle, action: #selector(menuCopy), keyEquivalent: "")
        let open = NSMenuItem(title: PopupWindowController.openInTabTitle, action: #selector(menuOpen), keyEquivalent: "")
        [copy, open].forEach { $0.target = self; menu.addItem($0) }
        return menu
    }

    @objc private func menuCopy() { onCopy?() }
    @objc private func menuOpen() { onOpenInTab?() }
}

/// Over the address: a click selects it, a drag moves the window as the rest of the strip does.
private final class AddressHit: NSView {
    var onClick: (() -> Void)?
    override var mouseDownCanMoveWindow: Bool { false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .iBeam) }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let start = event.locationInWindow
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp {
                onClick?()
                return
            }
            let p = next.locationInWindow
            if hypot(p.x - start.x, p.y - start.y) > 3 {
                if window.dragMovesWindow { window.performDrag(with: event) }
                return
            }
        }
    }
}

/// The selected address: says when it's let go, by Esc or by focus moving on.
private final class SelectableAddress: PlainTextField {
    var onEnd: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onEnd?() }
    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        let end = onEnd
        DispatchQueue.main.async { end?() }
    }
}

/// A sign-in popup's page, for extensions.
@available(macOS 15.4, *)
final class PopupTab: NSObject, WKWebExtensionTab {
    private(set) weak var popup: PopupWindowController?
    init(popup: PopupWindowController) { self.popup = popup }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { popup }
    func indexInWindow(for context: WKWebExtensionContext) -> Int { 0 }
    func webView(for context: WKWebExtensionContext) -> WKWebView? { popup?.webView }
    func title(for context: WKWebExtensionContext) -> String? { popup?.webView.title }
    func url(for context: WKWebExtensionContext) -> URL? { popup?.webView.url }
    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { popup?.webView.isLoading == false }
    func isSelected(for context: WKWebExtensionContext) -> Bool { true }
    func shouldGrantPermissionsOnUserGesture(for context: WKWebExtensionContext) -> Bool { true }

    func loadURL(_ url: URL, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        popup?.webView.load(URLRequest(url: Tab.extensionPageAddress(url)))
        completionHandler(nil)
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        popup?.window?.close()
        completionHandler(nil)
    }

    func reload(fromOrigin: Bool, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        _ = fromOrigin ? popup?.webView.reloadFromOrigin() : popup?.webView.reload()
        completionHandler(nil)
    }
}

/// The popup window itself, for extensions: a popup-type window holding its one page.
@available(macOS 15.4, *)
extension PopupWindowController: WKWebExtensionWindow {
    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] { [tab] }
    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? { tab }
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
        window?.close()
        completionHandler(nil)
    }
}
