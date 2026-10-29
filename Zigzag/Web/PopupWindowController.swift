import AppKit
import WebKit

/// Sign-in and payment popups (window.open with a size). A small real window that shows
/// which site you are talking to, keeps window.opener working, and closes itself when the page does.
final class PopupWindowController: NSWindowController, NSWindowDelegate, WKUIDelegate, WKNavigationDelegate {
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
    private var lastCrash: Date?

    static func open(configuration: WKWebViewConfiguration, features: WKWindowFeatures, parent: NSWindow?) -> WKWebView {
        let controller = PopupWindowController(configuration: configuration, features: features, parent: parent)
        Self.open.insert(controller)
        controller.showWindow(nil)
        if #available(macOS 15.4, *), !controller.isPrivate { ExtensionHost.shared.popupOpened(controller) }
        return controller.webView
    }

    private init(configuration: WKWebViewConfiguration, features: WKWindowFeatures, parent: NSWindow?) {
        webView = WKWebView(frame: .zero, configuration: configuration)
        let width = features.width.map { CGFloat($0.doubleValue) } ?? Tokens.Metric.popupDefaultSize.width
        let height = features.height.map { CGFloat($0.doubleValue) } ?? Tokens.Metric.popupDefaultSize.height
        let headerHeight = Tokens.Space.x8 + Tokens.Space.x1
        let size = NSSize(width: max(320, width), height: max(240, height) + headerHeight)

        var origin = NSPoint.zero
        if let x = features.x, let y = features.y, let screen = parent?.screen ?? NSScreen.main {
            origin = NSPoint(x: CGFloat(x.doubleValue), y: screen.frame.maxY - CGFloat(y.doubleValue) - size.height)
        } else if let parent {
            origin = NSPoint(x: parent.frame.midX - size.width / 2, y: parent.frame.midY - size.height / 2)
        }

        let window = PopupWindow(contentRect: NSRect(origin: origin, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.setFrameOrigin(origin)
        super.init(window: window)
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
        header.frame = NSRect(x: 0, y: 0, width: size.width, height: headerHeight)
        header.autoresizingMask = [.width]
        webView.frame = NSRect(x: 0, y: headerHeight, width: size.width, height: size.height - headerHeight)
        webView.autoresizingMask = [.width, .height]
        webView.uiDelegate = self
        webView.navigationDelegate = self
        webView.isInspectable = true

        observations = [
            webView.observe(\.url) { [weak self] wv, _ in MainActor.assumeIsolated { self?.updateHeader(); self?.tellExtensions(.URL) } },
            webView.observe(\.isLoading) { [weak self] _, _ in MainActor.assumeIsolated { self?.tellExtensions(.loading) } },
            webView.observe(\.hasOnlySecureContent) { [weak self] _, _ in MainActor.assumeIsolated { self?.updateHeader() } },
            webView.observe(\.title) { [weak self] wv, _ in MainActor.assumeIsolated { self?.window?.title = wv.title ?? ""; self?.tellExtensions(.title) } },
        ]
        updateHeader()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func tellExtensions(_ change: WKWebExtension.TabChangedProperties) {
        guard #available(macOS 15.4, *), !isPrivate, Self.open.contains(self) else { return }
        ExtensionHost.shared.popupChanged(self, change)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if #available(macOS 15.4, *), !isPrivate { ExtensionHost.shared.popupFocused(self) }
    }

    private func updateHeader() {
        header.show(url: webView.url, secure: webView.hasOnlySecureContent)
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
        window?.close()
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        PopupWindowController.open(configuration: configuration, features: windowFeatures, parent: window)
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
        if let url = navigationAction.request.url, ExternalLinks.isExternal(url), url.scheme?.lowercased() != "file" {
            ExternalLinks.open(url, isMainFrame: navigationAction.targetFrame?.isMainFrame ?? true,
                               isClick: navigationAction.navigationType == .linkActivated, from: webView)
            return .cancel
        }
        return .allow
    }

    /// The page's process crashed: load it again rather than leave a blank window, unless it just did the same.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        let again = lastCrash.map { Date().timeIntervalSince($0) < 10 } ?? false
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
        await AuthenticationPrompt.respond(to: challenge, window: window)
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

    override init(frame: NSRect) {
        super.init(frame: frame)
        lock.imageScaling = .scaleNone
        lock.contentTintColor = Tokens.Color.textSecondary
        addSubview(lock)
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    func show(url: URL?, secure: Bool) {
        label.stringValue = url?.host() ?? ""
        lock.image = Tokens.Symbol.image(secure ? "lock.fill" : "exclamationmark.triangle", size: Tokens.TypeSize.small)
        lock.isHidden = url == nil
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let textSize = NSSize(width: label.textWidth, height: label.lineHeight)
        let lockWidth = Tokens.Space.x3
        let total = lockWidth + Tokens.Space.x1 + ceil(textSize.width)
        let x = max(Tokens.Space.x16 + Tokens.Space.x4, (bounds.width - total) / 2)
        let h = ceil(textSize.height)
        lock.frame = NSRect(x: x, y: 0, width: lockWidth, height: bounds.height)
        label.frame = NSRect(x: lock.frame.maxX + Tokens.Space.x1, y: (bounds.height - h) / 2, width: min(ceil(textSize.width), bounds.width - x - Tokens.Space.x4), height: h)
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
