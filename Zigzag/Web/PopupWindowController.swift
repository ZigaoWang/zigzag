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
    private var parentObserver: Any?
    /// The browser window that opened it, where news about it (a pop-up it tried to open) is shown.
    private(set) weak var parentWindow: NSWindow?
    /// The strip at the top with the traffic lights and whose page it is.
    static let headerHeight = Tokens.Space.x8 + Tokens.Space.x1
    private var lastCrash: Date?

    static func open(configuration: WKWebViewConfiguration, features: WKWindowFeatures, parent: NSWindow?) -> WKWebView {
        let size = NSSize(width: features.width.map { CGFloat($0.doubleValue) } ?? Tokens.Metric.popupDefaultSize.width,
                          height: features.height.map { CGFloat($0.doubleValue) } ?? Tokens.Metric.popupDefaultSize.height)
        // A page's screenX and screenY count from the top left of the main display.
        var origin: NSPoint?
        if let x = features.x, let y = features.y, let top = NSScreen.screens.first?.frame.maxY {
            origin = NSPoint(x: CGFloat(x.doubleValue), y: top - CGFloat(y.doubleValue) - size.height)
        }
        let controller = PopupWindowController(configuration: configuration, pageSize: size, origin: origin, parent: parent)
        Self.open.insert(controller)
        // Sign-ins and payments run through these: which site opened one is often the clue.
        let opener = WindowManager.shared.controllers.first { $0.window === parent }?.tabManager.selectedTab?.url?.host()
        Diagnostics.note("Pop-up opened", site: opener, isPrivate: controller.isPrivate)
        controller.showWindow(nil)
        if #available(macOS 15.4, *), !controller.isPrivate { ExtensionHost.shared.popupOpened(controller) }
        return controller.webView
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
        ExtensionHost.shared.popupOpened(controller)
        return controller
    }

    private init(configuration: WKWebViewConfiguration, pageSize: NSSize, origin: NSPoint?, parent: NSWindow?) {
        webView = WKWebView(frame: .zero, configuration: configuration)
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
        // From a full-screen window, a sign-in popup opens over it in the same Space, not off in another one.
        if parent?.styleMask.contains(.fullScreen) == true { window.collectionBehavior.insert(.fullScreenAuxiliary) }
        window.setFrameOrigin(origin)
        super.init(window: window)
        parentWindow = parent
        window.delegate = self
        // Extensions' shortcuts (1Password's fill) work here too, before the page gets the keys.
        window.commandHandler = { [weak self] event in
            guard #available(macOS 15.4, *), let self, !self.isPrivate,
                  !event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
            return ExtensionHost.shared.performCommand(for: event)
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
        content.addSubview(webView)
        header.frame = NSRect(x: 0, y: 0, width: size.width, height: Self.headerHeight)
        header.autoresizingMask = [.width]
        webView.frame = NSRect(x: 0, y: Self.headerHeight, width: size.width, height: size.height - Self.headerHeight)
        webView.autoresizingMask = [.width, .height]
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
        ExtensionHost.shared.popupChanged(self, change)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if #available(macOS 15.4, *), !isPrivate { ExtensionHost.shared.popupFocused(self) }
    }

    /// The address of the page on screen: never one only on its way, which a page could start and never finish.
    private var shownURL: URL?

    private func updateHeader() {
        header.show(url: shownURL, secure: webView.hasOnlySecureContent)
    }

    /// Shows an extension's popup over this window, from the right end of its header, so it isn't hidden behind it.
    func showExtensionPopover(_ popover: NSPopover) {
        window?.makeKeyAndOrderFront(nil)
        let spot = NSRect(x: header.bounds.maxX - Tokens.Space.x8, y: 0, width: Tokens.Space.x4, height: header.bounds.height)
        popover.behavior = .semitransient
        popover.show(relativeTo: spot, of: header, preferredEdge: .maxY)
    }

    func windowWillClose(_ notification: Notification) {
        observations.forEach { $0.invalidate() }
        webView.stopLoading()
        if let parentObserver { NotificationCenter.default.removeObserver(parentObserver) }
        parentObserver = nil
        if #available(macOS 15.4, *), !isPrivate, Self.open.contains(self) { ExtensionHost.shared.popupClosed(self) }
        Self.open.remove(self)
    }

    func webViewDidClose(_ webView: WKWebView) {
        Diagnostics.note("Pop-up closed itself", site: webView.url?.host(), isPrivate: isPrivate)
        window?.close()
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard PopupNotice.allows(navigationAction, from: webView.url, isPrivate: isPrivate),
              Tab.mayOpenInNewWebView(navigationAction.request.url) else { return nil }
        // A plain link (a help page, the terms) opens as a tab in the browser window, brought forward, as a
        // browser would; only another sized window.open() is a popup of its own.
        let sized = windowFeatures.width != nil || windowFeatures.height != nil || windowFeatures.toolbarsVisibility?.boolValue == false
        if !sized, let controller = WindowManager.shared.controllers.first(where: { $0.window === parentWindow }) {
            let tab = controller.tabManager.newTab(url: nil, configuration: configuration)
            controller.window?.makeKeyAndOrderFront(nil)
            return tab.ensureWebView()
        }
        return PopupWindowController.open(configuration: configuration, features: windowFeatures, parent: window)
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

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        if navigationAction.shouldPerformDownload { return .download }
        // Zigzag's own pages (History) open in its tabs, never in a page's pop-up.
        if navigationAction.request.url?.scheme?.lowercased() == HistoryPage.scheme { return .cancel }
        if let url = navigationAction.request.url, ExternalLinks.isExternal(url), url.scheme?.lowercased() != "file" {
            ExternalLinks.open(url, isMainFrame: navigationAction.targetFrame?.isMainFrame ?? true,
                               isClick: PopupNotice.isUserInitiated(navigationAction), from: webView,
                               asker: navigationAction.sourceFrame.securityOrigin)
            return .cancel
        }
        return .allow
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        PageDialogs.pageLoaded(webView)
        shownURL = webView.url
        updateHeader()
    }

    /// A page that never arrived says why, as a tab does, rather than leave the window blank.
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        // It never came: the header stays on the page still showing.
        shownURL = webView.url
        updateHeader()
        let nsError = error as NSError
        if nsError.code == NSURLErrorCancelled || (nsError.domain == "WebKitErrorDomain" && [102, 204].contains(nsError.code)) { return }
        let failingURL = (nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? webView.url
        Diagnostics.note("Pop-up didn’t load", site: failingURL?.host(), Diagnostics.describe(nsError), isPrivate: isPrivate)
        ErrorPage.show(error: nsError, url: failingURL, in: webView, canProceed: false)
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
        navigationResponse.canShowMIMEType ? .allow : .download
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

    func webView(_ webView: WKWebView, respondTo challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        await AuthenticationPrompt.respond(to: challenge, window: window, store: webView.configuration.websiteDataStore, page: webView, tab: isPrivate ? nil : tab)
    }
}

/// The popup's window: it lets extensions' shortcuts have the keys first, as the browser window does.
private final class PopupWindow: NSWindow {
    var commandHandler: ((NSEvent) -> Bool)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, commandHandler?(event) == true { return }
        super.sendEvent(event)
    }
}

/// The popup's top strip: traffic lights on the left, the site's full host in the middle.
final class PopupHeaderView: NSView {
    private let label = Label("", font: Tokens.Font.body(.medium), color: Tokens.Color.textPrimary)
    private let lock = NSImageView()
    /// Room kept clear at the right end for buttons laid over the strip (Zigzag Mini's Open in Zigzag).
    var trailingInset: CGFloat = 0 { didSet { needsLayout = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        lock.imageScaling = .scaleNone
        lock.contentTintColor = Tokens.Color.textSecondary
        addSubview(lock)
        // A long host loses its start, never its end, which says whose site it is.
        label.lineBreakMode = .byTruncatingHead
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    func show(url: URL?, secure: Bool) {
        // An extension's own page: whose it is, not an address no one could read.
        if #available(macOS 15.4, *), let url, url.scheme == "webkit-extension",
           let context = ExtensionHost.shared.contexts.first(where: { $0.baseURL.host() == url.host() }) {
            label.stringValue = context.webExtension.displayName ?? ""
            lock.image = Tokens.Symbol.image("puzzlepiece.extension", size: Tokens.Symbol.inline)
            lock.isHidden = false
            lock.setAccessibilityLabel(String(localized: "Extension", comment: "VoiceOver label of the icon before an extension's address in a pop-up window."))
            needsLayout = true
            return
        }
        // No site at all (data:): said so, and no lock, which would vouch for a site that isn't there.
        let site = Self.site(of: url)
        label.stringValue = site ?? AddressView.name(of: url)
        lock.isHidden = site == nil
        lock.image = Tokens.Symbol.image(secure ? "lock" : "exclamationmark.triangle", size: Tokens.Symbol.inline)
        lock.setAccessibilityLabel(secure ? String(localized: "Secure connection", comment: "VoiceOver label of the lock before the address in a pop-up window.")
                                           : String(localized: "Not secure", comment: "VoiceOver label of the warning before the address in a pop-up window."))
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
        let textSize = NSSize(width: label.textWidth, height: label.lineHeight)
        // Without its lock, the name alone is centered.
        let lockWidth = lock.isHidden ? 0 : Tokens.Space.x3
        let gap = lock.isHidden ? 0 : Tokens.Space.x1
        let total = lockWidth + gap + ceil(textSize.width)
        let x = max(Tokens.Space.x16 + Tokens.Space.x4, (bounds.width - total) / 2)
        let h = ceil(textSize.height)
        lock.frame = NSRect(x: x, y: 0, width: lockWidth, height: bounds.height)
        label.frame = NSRect(x: lock.frame.maxX + gap, y: (bounds.height - h) / 2, width: max(0, min(ceil(textSize.width), bounds.width - x - Tokens.Space.x4 - trailingInset)), height: h)
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
        popup?.webView.load(URLRequest(url: url))
        completionHandler(nil)
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        popup?.window?.close()
        completionHandler(nil)
    }

    func reload(fromOrigin: Bool, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        fromOrigin ? popup?.webView.reloadFromOrigin() : popup?.webView.reload()
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
    func isPrivate(for context: WKWebExtensionContext) -> Bool { false }
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
