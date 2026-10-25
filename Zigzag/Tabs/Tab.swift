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
        case title, url, favicon, loading, progress, navigation, audio, themeColor, activity, snapshot, webView, capture, reader, language
    }

    let id: UUID
    var spaceID: UUID
    /// Set when this tab is the live page behind a bookmark. Such tabs live in the bookmark row, not the tab list.
    var bookmarkID: UUID?
    /// Set when this tab is the live page behind a favorite tile.
    var isFavorite = false

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
    /// Set for tabs in a private window: their own throwaway storage, and nothing remembered.
    var privateStore: WKWebsiteDataStore?
    var isPrivate: Bool { privateStore != nil }
    /// In a call (camera or microphone on, even muted) or floating in Picture in Picture: not to be put to sleep.
    var isInUse: Bool {
        guard let webView else { return false }
        return webView.cameraCaptureState != .none || webView.microphoneCaptureState != .none || webView.isPictureInPictureActive
    }
    /// The tab that opened this one, so closing it can return there.
    weak var opener: Tab?

    weak var host: TabHost?
    /// When its page last stopped unexpectedly, to tell a one-off from a page that keeps stopping.
    private var crashes: [Date] = []
    private var reloadWhenShown = false
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
    /// A name you gave the tab (double-click to rename); it stays whatever the page calls itself.
    /// While a pinned page is first loading, where it ends up on its own (a site that redirects, like
    /// calendar.google.com) counts as the pinned page, so it's never "moved on" before you've done anything.
    var landingUntil: Date?
    var pinnedLanding: URL?
    var customTitle: String? { didSet { if oldValue != customTitle { changed.send(.title) } } }

    var displayTitle: String {
        if let customTitle, !customTitle.isEmpty { return customTitle }
        if !title.isEmpty { return title }
        return url?.host() ?? "New Tab"
    }
    var isBlank: Bool { url == nil }

    // MARK: Web view lifecycle

    /// Returns the live web view, creating or restoring it if needed.
    @discardableResult
    func ensureWebView() -> BrowserWebView {
        if let webView { return webView }
        let fromWebKit = pendingConfiguration != nil
        let extensionConfiguration = fromWebKit ? nil : Self.extensionConfiguration(for: url)
        let configuration = pendingConfiguration ?? extensionConfiguration ?? WebKitSetup.makeConfiguration()
        pendingConfiguration = nil
        if extensionConfiguration != nil {
            configuration.applicationNameForUserAgent = WebKitSetup.applicationNameForUserAgent
        } else if !fromWebKit {
            WebKitSetup.configure(configuration)
            if let privateStore { configuration.websiteDataStore = privateStore }
        }
        showsExtensionPage = extensionConfiguration != nil
        if Self.isExtensionPage(url) { ExtensionPageErrors.attach(to: configuration) }

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

        if Self.isExtensionPage(url), let url {
            // Extension pages always load fresh: their saved history state can come back as a blank page, and one
            // from an extension that's gone gets explained rather than restored.
            pendingInteractionState = nil
            Self.load(url, in: webView)
        } else if let state = pendingInteractionState {
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

    /// `keepingSnapshot`: its window closed but the tab may come back (reopening the last window), so its
    /// thumbnail stays until the next save prunes what isn't kept.
    func close(keepingSnapshot: Bool = false) {
        if let webView { tearDown(webView) }
        if !keepingSnapshot { SnapshotStore.remove(id) }
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
        // Extension pages and websites need differently set up web views; crossing over swaps it.
        if let webView, Self.isExtensionPage(url) != showsExtensionPage {
            tearDown(webView)
            ensureWebView()
            return
        }
        let webView = ensureWebView()
        Self.load(url, in: webView)
    }

    /// The page looks like an article, so Reader is offered.
    private(set) var isArticle = false
    /// The page's language, when it isn't the reader's and can be translated.
    private(set) var foreignLanguage: Locale.Language?
    /// The page's text is shown translated.
    var isTranslated = false

    /// Set when switching away floated this tab's video, so switching back can put it back.
    var floatedOnSwitch = false

    /// True while the web view was built for an extension's own pages (settings, dashboards).
    private var showsExtensionPage = false

    static func isExtensionPage(_ url: URL?) -> Bool { url?.scheme == "webkit-extension" }

    /// WebKit shows an extension's pages only in a web view set up by that extension.
    private static func extensionConfiguration(for url: URL?) -> WKWebViewConfiguration? {
        guard #available(macOS 15.4, *), isExtensionPage(url), let host = url?.host() else { return nil }
        return ExtensionHost.shared.contexts.first { $0.baseURL.host() == host }?.webViewConfiguration
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
        // WebKit quietly ignores a page from an extension it doesn't have; say what happened instead.
        if isExtensionPage(url), extensionConfiguration(for: url) == nil {
            // Opened by an extension that's still loading (1Password's welcome page, right after it installs):
            // wait for it, briefly, before saying the page is unavailable.
            if #available(macOS 15.4, *) {
                var token: SignalToken?
                var waited = false
                token = ExtensionHost.shared.changed.observe { [weak webView] in
                    guard let webView, !waited, extensionConfiguration(for: url) != nil else { return }
                    waited = true
                    token = nil
                    (webView as? BrowserWebView)?.owner?.load(url)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak webView] in
                    guard !waited, let webView else { return }
                    waited = true
                    token = nil
                    ErrorPage.show(error: NSError(domain: NSURLErrorDomain, code: NSURLErrorResourceUnavailable), url: url, in: webView)
                }
                _ = token
                return
            }
            ErrorPage.show(error: NSError(domain: NSURLErrorDomain, code: NSURLErrorResourceUnavailable), url: url, in: webView)
            return
        }
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

    // MARK: Camera and microphone

    var isUsingCamera: Bool { webView?.cameraCaptureState == .active }
    var isUsingMicrophone: Bool { webView?.microphoneCaptureState == .active }

    func stopCapture() {
        webView?.setCameraCaptureState(.none) { }
        webView?.setMicrophoneCaptureState(.none) { }
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
                if !self.isPrivate { SnapshotStore.save(image, for: self.id) }
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
                    if let url = self.url, !self.isPrivate { HistoryStore.shared.updateTitle(title, for: url) }
                }
            },
            webView.observe(\.url, options: [.new]) { [weak self] wv, _ in
                MainActor.assumeIsolated {
                    guard let self, let url = wv.url else { return }
                    let hostChanged = url.host() != self.url?.host()
                    if url != self.url, self.isArticle { self.isArticle = false; self.changed.send(.reader) }
                    if url != self.url, self.foreignLanguage != nil || self.isTranslated {
                        self.foreignLanguage = nil
                        self.isTranslated = false
                        self.changed.send(.language)
                    }
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
            webView.observe(\.cameraCaptureState, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.changed.send(.capture) }
            },
            webView.observe(\.microphoneCaptureState, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.changed.send(.capture) }
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
        // Private tabs only use icons already saved from normal browsing; they never fetch or save one.
        if isPrivate || Self.isExtensionPage(pageURL) {
            favicon = FaviconStore.shared.cachedIcon(for: pageURL)
            changed.send(.favicon)
            return
        }
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

        // Schemes the web view cannot handle go to the system (mailto:, facetime:, app links). Extension pages stay here.
        if ExternalLinks.isExternal(url) {
            ExternalLinks.open(url, isMainFrame: navigationAction.targetFrame?.isMainFrame ?? true,
                               isClick: navigationAction.navigationType == .linkActivated, from: webView)
            return (.cancel, preferences)
        }

        // The page's ad blocking follows where it's going: allowed sites load without it.
        if navigationAction.targetFrame?.isMainFrame ?? true, !showsExtensionPage {
            ContentBlocker.apply(to: webView, for: url)
        }

        // Going between an extension's pages and the web takes a different web view.
        if navigationAction.targetFrame?.isMainFrame ?? true, Self.isExtensionPage(url) != showsExtensionPage,
           ["http", "https", "webkit-extension"].contains(url.scheme?.lowercased() ?? "") {
            DispatchQueue.main.async { [weak self] in self?.load(url) }
            return (.cancel, preferences)
        }

        let isLinkClick = navigationAction.navigationType == .linkActivated
        // Anything you do yourself ends the pinned page's settling-in.
        if isLinkClick || navigationAction.navigationType == .formSubmitted { landingUntil = nil }
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
        let response = navigationResponse.response
        let mime = (response.mimeType ?? "").lowercased()
        let disposition = ((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition") ?? "").lowercased()
        // A web page is shown, always. WebKit can briefly say it can't show HTML (a response handed over by a
        // service worker, as YouTube's first load does), and a page saved as "youtube.com.html" is never right.
        let isWebPage = mime.isEmpty || ["text/html", "application/xhtml+xml", "text/plain", "application/json", "text/xml", "application/xml"].contains(mime)
        let isAttachment = disposition.hasPrefix("attachment") && (!isWebPage || disposition.contains("filename"))
        let policy: WKNavigationResponsePolicy
        if isAttachment {
            policy = .download
        } else if isWebPage || navigationResponse.canShowMIMEType {
            policy = .allow
        } else {
            // Files in frames aren't saved behind the person's back; only the page itself can start a download.
            policy = navigationResponse.isForMainFrame ? .download : .cancel
        }
        #if DEBUG
        if policy == .download {
            debugLog("download chosen: mime=\(mime) canShow=\(navigationResponse.canShowMIMEType) mainFrame=\(navigationResponse.isForMainFrame) attachment=\(!disposition.isEmpty)")
        }
        #endif
        return policy
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
        // A sign-in menu belongs to the page it opened on.
        Autofill.shared.hide()
        hasLoadedOnce = true
        if let url = webView.url {
            let zoom = ZoomLevels.zoom(for: url)
            if webView.pageZoom != zoom { webView.pageZoom = zoom }
            if isSearchTab, !SearchFolding.isSearchResultsPage(url) { isSearchTab = false }
            if !isPrivate { HistoryStore.shared.recordVisit(url: url, title: webView.title) }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let until = landingUntil, Date() < until, let url = webView.url { pinnedLanding = url }
        refreshFavicon()
        Task { [weak self] in
            let article = await Reader.isArticle(webView)
            guard let self, self.webView === webView, article != self.isArticle else { return }
            self.isArticle = article
            self.changed.send(.reader)
        }
        Task { [weak self] in
            let language = await PageTranslator.foreignLanguage(of: webView)
            guard let self, self.webView === webView else { return }
            self.foreignLanguage = language
            self.changed.send(.language)
        }
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
        // Out of sight, it waits until it's next shown: memory pressure doesn't reload every background tab at once.
        guard webView.window != nil else { reloadWhenShown = true; return }
        let now = Date()
        crashes = crashes.filter { now.timeIntervalSince($0) < 60 } + [now]
        // Twice in a minute: say so, rather than crash and reload forever.
        if crashes.count >= 2 {
            ErrorPage.show(error: NSError(domain: ErrorPage.crashDomain, code: 1), url: url ?? webView.url, in: webView)
            return
        }
        // Crashed before anything loaded: load its address, since there's nothing to reload.
        if webView.url == nil, let url { Self.load(url, in: webView) } else { webView.reload() }
    }

    /// Shown again after its page stopped while out of sight.
    func reloadIfItStopped() {
        guard reloadWhenShown, let webView else { return }
        reloadWhenShown = false
        if webView.url == nil, let url { Self.load(url, in: webView) } else { webView.reload() }
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
        await SitePermissions.request(origin: origin, type: type, window: host?.hostWindow, isPrivate: isPrivate)
    }
}
