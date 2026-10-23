import AppKit
import WebKit

/// What a tab asks of the window that shows it.
protocol TabHost: AnyObject {
    var hostWindow: NSWindow? { get }
    func tab(_ tab: Tab, openURL url: URL, disposition: OpenDisposition)
    func tab(_ tab: Tab, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, features: WKWindowFeatures) -> WKWebView?
    func tabDidRequestClose(_ tab: Tab)
    func tabDidChangeFullscreen(_ tab: Tab, isFullscreen: Bool)
    func tab(_ tab: Tab, hoveringLink url: URL?)
}

enum OpenDisposition {
    case currentTab
    case foregroundTab
    case backgroundTab
    case peek
    case newWindow
}

/// One page in the browser. The tab owns its web view; views only borrow it to display.
/// A tab can be suspended (web view released, state kept) and restored without the user noticing.
final class Tab: NSObject {
    enum Change {
        case title, url, favicon, loading, progress, navigation, audio, themeColor, activity, snapshot, webView
    }

    let id: UUID
    var spaceID: UUID
    /// Set when this tab is the live page behind a bookmark. Such tabs live in the bookmark row, not the tab list.
    var bookmarkID: UUID?

    private(set) var url: URL?
    private(set) var title: String
    private(set) var favicon: NSImage?
    private(set) var themeColor: NSColor?
    private(set) var isLoading = false
    private(set) var progress: Double = 0
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var isPlayingAudio = false
    private(set) var isMuted = false
    private(set) var hasLoadedOnce = false
    private(set) var snapshot: NSImage?
    var lastActivated: Date
    let createdAt: Date
    /// True for a tab opened by a search from the command bar, until the user leaves the results page.
    var isSearchTab = false
    /// True while the page lives in the peek card rather than the tab list.
    var isPeek = false
    /// The tab that opened this one, so closing it can return there.
    weak var opener: Tab?

    weak var host: TabHost?
    let changed = Signal<Change>()

    private(set) var webView: BrowserWebView?
    /// Back/forward history and scroll position kept while suspended or across launches.
    private var pendingInteractionState: Data?
    private var pendingConfiguration: WKWebViewConfiguration?
    private var observations: [NSKeyValueObservation] = []
    private var observingAudio = false

    init(id: UUID = UUID(), url: URL?, title: String? = nil, spaceID: UUID, configuration: WKWebViewConfiguration? = nil,
         interactionState: Data? = nil, lastActivated: Date = Date(), createdAt: Date = Date()) {
        self.id = id
        self.url = url
        self.title = title ?? url?.host() ?? "New Tab"
        self.spaceID = spaceID
        self.pendingConfiguration = configuration
        self.pendingInteractionState = interactionState
        self.lastActivated = lastActivated
        self.createdAt = createdAt
        super.init()
        if let url { favicon = FaviconStore.shared.cachedIcon(for: url) }
        snapshot = SnapshotStore.load(id)
        if #available(macOS 15.4, *) {
            extensionToken = changed.observe { [weak self] change in
                guard let self else { return }
                ExtensionHost.shared.tabChanged(self, change)
            }
        }
    }

    private var extensionToken: SignalToken?

    var isSuspended: Bool { webView == nil }
    var displayTitle: String {
        if !title.isEmpty { return title }
        return url?.host() ?? "New Tab"
    }
    var isBlank: Bool { url == nil }

    // MARK: Web view lifecycle

    /// Returns the live web view, creating or restoring it if needed.
    @discardableResult
    func ensureWebView() -> BrowserWebView {
        if let webView { return webView }
        let configuration = pendingConfiguration ?? WebKitSetup.makeConfiguration()
        let fromWebKit = pendingConfiguration != nil
        pendingConfiguration = nil
        if !fromWebKit { WebKitSetup.configure(configuration) }

        let webView = BrowserWebView(frame: NSRect(origin: .zero, size: Tokens.Metric.windowDefaultSize), configuration: configuration)
        webView.owner = self
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.isInspectable = true
        #if DEBUG
        // Lets scripted screenshots capture pages while the window is behind other apps.
        let occlusion = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        if webView.responds(to: occlusion) {
            typealias SetBool = @convention(c) (AnyObject, Selector, Bool) -> Void
            unsafeBitCast(webView.method(for: occlusion), to: SetBool.self)(webView, occlusion, false)
        }
        #endif
        self.webView = webView
        observe(webView)

        if let state = pendingInteractionState {
            webView.interactionState = state as NSData
            pendingInteractionState = nil
            // Interaction state restores history but may not start a load on its own.
            if webView.url == nil, let url { Self.load(url, in: webView) }
        } else if let url, !fromWebKit {
            Self.load(url, in: webView)
        }
        changed.send(.webView)
        return webView
    }

    /// Releases the web view but keeps everything needed to bring it back.
    func suspend() {
        guard let webView, !isPlayingAudio else { return }
        captureSnapshot { [weak self] in
            guard let self, self.webView === webView else { return }
            self.pendingInteractionState = webView.interactionState as? Data
            self.tearDown(webView)
            self.changed.send(.webView)
        }
    }

    func close() {
        if let webView { tearDown(webView) }
        SnapshotStore.remove(id)
    }

    private func tearDown(_ webView: BrowserWebView) {
        observations.forEach { $0.invalidate() }
        observations = []
        if observingAudio {
            webView.removeObserver(self, forKeyPath: "_isPlayingAudio")
            observingAudio = false
        }
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.owner = nil
        webView.removeFromSuperview()
        self.webView = nil
        isLoading = false
        isPlayingAudio = false
    }

    /// History snapshot for session restore. Cheap when the web view is suspended.
    var interactionStateForSaving: Data? {
        if let webView { return webView.interactionState as? Data }
        return pendingInteractionState
    }

    // MARK: Navigation

    func load(_ url: URL) {
        self.url = url
        changed.send(.url)
        let webView = ensureWebView()
        Self.load(url, in: webView)
    }

    /// Starts this tab with another tab's back/forward list, then navigates: used for search folding.
    func restoreHistory(_ state: Data, thenLoad url: URL) {
        if let webView {
            webView.interactionState = state as NSData
        } else {
            pendingInteractionState = state
        }
        let webView = ensureWebView()
        self.url = url
        changed.send(.url)
        Self.load(url, in: webView)
    }

    /// Local files need read access granted to their folder; everything else is a plain request.
    static func load(_ url: URL, in webView: WKWebView) {
        if url.isFileURL {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView.load(URLRequest(url: url))
        }
    }

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }
    func reload() {
        guard let webView else { ensureWebView(); return }
        if webView.url == nil, let url { webView.load(URLRequest(url: url)) } else { webView.reload() }
    }
    func reloadFromOrigin() { webView?.reloadFromOrigin() }
    func stopLoading() { webView?.stopLoading() }

    func markActivated() {
        lastActivated = Date()
        changed.send(.activity)
    }

    // MARK: Audio

    func setMuted(_ muted: Bool) {
        guard let webView else { return }
        let selector = NSSelectorFromString("_setPageMuted:")
        if webView.responds(to: selector) {
            typealias SetMuted = @convention(c) (AnyObject, Selector, UInt) -> Void
            let imp = unsafeBitCast(webView.method(for: selector), to: SetMuted.self)
            imp(webView, selector, muted ? 1 : 0)
        } else {
            webView.evaluateJavaScript("document.querySelectorAll('audio,video').forEach(m => m.muted = \(muted))")
        }
        isMuted = muted
        changed.send(.audio)
    }

    /// Pauses (or resumes) everything the page is playing, through WebKit's own media control.
    private(set) var isPlaybackPaused = false

    func setPlaybackPaused(_ paused: Bool) {
        guard let webView else { return }
        isPlaybackPaused = paused
        webView.setAllMediaPlaybackSuspended(paused) { }
        changed.send(.audio)
    }

    // MARK: Snapshots

    func captureSnapshot(_ completion: (() -> Void)? = nil) {
        guard let webView, webView.window != nil, webView.bounds.width > 0, hasLoadedOnce else { completion?(); return }
        let config = WKSnapshotConfiguration()
        config.afterScreenUpdates = false
        config.snapshotWidth = NSNumber(value: Double(min(webView.bounds.width, 1280)))
        webView.takeSnapshot(with: config) { [weak self] image, _ in
            guard let self else { return }
            if let image {
                self.snapshot = image
                SnapshotStore.save(image, for: self.id)
                self.changed.send(.snapshot)
            }
            completion?()
        }
    }

    // MARK: Observation

    private func observe(_ webView: BrowserWebView) {
        observations = [
            webView.observe(\.title, options: [.new]) { [weak self] wv, _ in
                MainActor.assumeIsolated {
                    guard let self, let title = wv.title, !title.isEmpty else { return }
                    self.title = title
                    self.changed.send(.title)
                    if let url = self.url { HistoryStore.shared.updateTitle(title, for: url) }
                }
            },
            webView.observe(\.url, options: [.new]) { [weak self] wv, _ in
                MainActor.assumeIsolated {
                    guard let self, let url = wv.url else { return }
                    let hostChanged = url.host() != self.url?.host()
                    self.url = url
                    if hostChanged { self.favicon = FaviconStore.shared.cachedIcon(for: url) ?? self.favicon; self.changed.send(.favicon) }
                    self.changed.send(.url)
                }
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self] wv, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isLoading = wv.isLoading
                    self.changed.send(.loading)
                }
            },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] wv, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.progress = wv.estimatedProgress
                    self.changed.send(.progress)
                }
            },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] wv, _ in
                MainActor.assumeIsolated {
                    self?.canGoBack = wv.canGoBack
                    self?.changed.send(.navigation)
                }
            },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] wv, _ in
                MainActor.assumeIsolated {
                    self?.canGoForward = wv.canGoForward
                    self?.changed.send(.navigation)
                }
            },
            webView.observe(\.themeColor, options: [.new]) { [weak self] wv, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.themeColor = wv.themeColor
                    self.changed.send(.themeColor)
                }
            },
        ]
        if webView.responds(to: NSSelectorFromString("_isPlayingAudio")) {
            webView.addObserver(self, forKeyPath: "_isPlayingAudio", options: [.new], context: nil)
            observingAudio = true
        }
    }

    override nonisolated func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        guard keyPath == "_isPlayingAudio" else { return }
        let playing = (change?[.newKey] as? Bool) ?? false
        MainActor.assumeIsolated {
            self.isPlayingAudio = playing
            self.changed.send(.audio)
        }
    }

    fileprivate func refreshFavicon() {
        guard let webView, let pageURL = webView.url else { return }
        webView.evaluateJavaScript(PageScripts.iconLinks) { [weak self] result, _ in
            MainActor.assumeIsolated {
                let links = (result as? [[String: String]]) ?? []
                FaviconStore.shared.resolve(pageURL: pageURL, links: links) { image in
                    guard let self, let image, self.url?.host() == pageURL.host() else { return }
                    self.favicon = image
                    self.changed.send(.favicon)
                }
            }
        }
    }

    // MARK: Restoring visible state from a saved session

    func restoreDisplayState(title: String?, url: URL?) {
        if let title { self.title = title }
        if let url { self.url = url }
    }
}

// MARK: - WKNavigationDelegate

extension Tab: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        if navigationAction.shouldPerformDownload { return (.download, preferences) }

        guard let url = navigationAction.request.url else { return (.cancel, preferences) }

        // Schemes the web view cannot handle go to the system (mailto:, facetime:, app links).
        if let scheme = url.scheme?.lowercased(), !["http", "https", "about", "data", "blob", "file", "javascript"].contains(scheme) {
            NSWorkspace.shared.open(url)
            return (.cancel, preferences)
        }

        let isLinkClick = navigationAction.navigationType == .linkActivated
        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        if isLinkClick && isMainFrame {
            let flags = navigationAction.modifierFlags
            if navigationAction.buttonNumber == 4 /* middle click */ || flags.contains(.command) {
                host?.tab(self, openURL: url, disposition: flags.contains(.shift) ? .foregroundTab : .backgroundTab)
                return (.cancel, preferences)
            }
            if flags.contains(.shift) {
                host?.tab(self, openURL: url, disposition: .peek)
                return (.cancel, preferences)
            }
            if flags.contains(.option) {
                return (.download, preferences)
            }
        }
        return (.allow, preferences)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if let response = navigationResponse.response as? HTTPURLResponse,
           let disposition = response.value(forHTTPHeaderField: "Content-Disposition"),
           disposition.lowercased().hasPrefix("attachment") {
            return .download
        }
        return navigationResponse.canShowMIMEType ? .allow : .download
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        DownloadManager.shared.track(download, window: host?.hostWindow)
        closeIfOnlyADownload(webView)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        DownloadManager.shared.track(download, window: host?.hostWindow)
        closeIfOnlyADownload(webView)
    }

    /// A tab opened just to fetch a file has nothing to show; it goes away once the download starts.
    private func closeIfOnlyADownload(_ webView: WKWebView) {
        guard !hasLoadedOnce, webView.backForwardList.currentItem == nil, bookmarkID == nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.host?.tabDidRequestClose(self)
        }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        hasLoadedOnce = true
        if let url = webView.url {
            let zoom = ZoomLevels.zoom(for: url)
            if webView.pageZoom != zoom { webView.pageZoom = zoom }
            if isSearchTab, !SearchFolding.isSearchResultsPage(url) { isSearchTab = false }
            HistoryStore.shared.recordVisit(url: url, title: webView.title)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        refreshFavicon()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handle(error, in: webView)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handle(error, in: webView)
    }

    private func handle(_ error: Error, in webView: WKWebView) {
        let nsError = error as NSError
        // Cancelled loads, frame-load-interrupted (downloads, policy changes) are not failures.
        if nsError.code == NSURLErrorCancelled || (nsError.domain == "WebKitErrorDomain" && nsError.code == 102) { return }
        let failingURL = (nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? url
        ErrorPage.show(error: nsError, url: failingURL, in: webView)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // A crashed page reloads quietly instead of leaving a blank card.
        webView.reload()
    }

    func webView(_ webView: WKWebView, respondTo challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        await AuthenticationPrompt.respond(to: challenge, window: host?.hostWindow)
    }
}

// MARK: - WKUIDelegate

extension Tab: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        host?.tab(self, createWebViewWith: configuration, for: navigationAction, features: windowFeatures)
    }

    func webViewDidClose(_ webView: WKWebView) {
        host?.tabDidRequestClose(self)
    }

    /// Reported by our hover script: the link under the pointer, or nil.
    func hoveredLinkChanged(_ url: URL?) {
        host?.tab(self, hoveringLink: url)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {
        await PageDialogs.alert(message: message, frame: frame, window: host?.hostWindow)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
        await PageDialogs.confirm(message: message, frame: frame, window: host?.hostWindow)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo) async -> String? {
        await PageDialogs.prompt(message: prompt, defaultText: defaultText, frame: frame, window: host?.hostWindow)
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        await PageDialogs.openPanel(parameters: parameters, window: host?.hostWindow)
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType) async -> WKPermissionDecision {
        .prompt
    }
}
