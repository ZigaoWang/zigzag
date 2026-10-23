import AppKit
import WebKit

/// Sign-in and payment popups (window.open with a size). A small real window that shows
/// which site you are talking to, keeps window.opener working, and closes itself when the page does.
final class PopupWindowController: NSWindowController, NSWindowDelegate, WKUIDelegate, WKNavigationDelegate {
    private static var open: Set<PopupWindowController> = []

    let webView: WKWebView
    private var observations: [NSKeyValueObservation] = []
    private let header = PopupHeaderView()

    static func open(configuration: WKWebViewConfiguration, features: WKWindowFeatures, parent: NSWindow?) -> WKWebView {
        let controller = PopupWindowController(configuration: configuration, features: features, parent: parent)
        Self.open.insert(controller)
        controller.showWindow(nil)
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

        let window = NSWindow(contentRect: NSRect(origin: origin, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.setFrameOrigin(origin)
        super.init(window: window)
        window.delegate = self

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
            webView.observe(\.url) { [weak self] wv, _ in MainActor.assumeIsolated { self?.updateHeader() } },
            webView.observe(\.hasOnlySecureContent) { [weak self] _, _ in MainActor.assumeIsolated { self?.updateHeader() } },
            webView.observe(\.title) { [weak self] wv, _ in MainActor.assumeIsolated { self?.window?.title = wv.title ?? "" } },
        ]
        updateHeader()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func updateHeader() {
        header.show(url: webView.url, secure: webView.hasOnlySecureContent)
    }

    func windowWillClose(_ notification: Notification) {
        observations.forEach { $0.invalidate() }
        webView.stopLoading()
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

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        await PageDialogs.openPanel(parameters: parameters, window: window)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        if navigationAction.shouldPerformDownload { return .download }
        if let url = navigationAction.request.url, let scheme = url.scheme?.lowercased(),
           !["http", "https", "about", "data", "blob", "javascript"].contains(scheme) {
            NSWorkspace.shared.open(url)
            return .cancel
        }
        return .allow
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

    func webView(_ webView: WKWebView, respondTo challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        await AuthenticationPrompt.respond(to: challenge, window: window)
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
        let textSize = label.intrinsicContentSize
        let lockWidth = Tokens.Space.x3
        let total = lockWidth + Tokens.Space.x1 + ceil(textSize.width)
        let x = max(Tokens.Space.x16 + Tokens.Space.x4, (bounds.width - total) / 2)
        let h = ceil(textSize.height)
        lock.frame = NSRect(x: x, y: 0, width: lockWidth, height: bounds.height)
        label.frame = NSRect(x: lock.frame.maxX + Tokens.Space.x1, y: (bounds.height - h) / 2, width: min(ceil(textSize.width), bounds.width - x - Tokens.Space.x4), height: h)
    }
}
