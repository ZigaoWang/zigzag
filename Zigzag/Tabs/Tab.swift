import AppKit
import WebKit

/// What a tab asks of the window that shows it.
protocol TabHost: AnyObject {
    var hostWindow: NSWindow? { get }
    func tab(_ tab: Tab, openURL url: URL, disposition: OpenDisposition)
    func tab(_ tab: Tab, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, features: WKWindowFeatures) -> WKWebView?
    func tabDidRequestClose(_ tab: Tab)
    /// Back from a tab a link opened, with no page before this one in it.
    func tabWantsToReturnToOpener(_ tab: Tab)
    func tab(_ tab: Tab, hoveringLink url: URL?)
    /// Its floating video's Return button: bring it on screen, so the video can go back into the page.
    func tabWantsToBeShown(_ tab: Tab)
    /// Swiped back or forward in its page: in a split, that page becomes the one you're in, as a click on it would.
    func tabWantsFocus(_ tab: Tab)
}

extension TabHost {
    func tabWantsFocus(_ tab: Tab) {}
}

enum OpenDisposition {
    case currentTab
    case foregroundTab
    case backgroundTab
    case peek
    case newWindow
    case privateWindow
}

/// One page in the browser. The tab owns its web view and the holder it sits in; views only borrow the holder to display.
/// A tab can be suspended (web view released, state kept) and restored without the user noticing.
final class Tab: NSObject {
    enum Change {
        case title, url, favicon, loading, progress, navigation, audio, themeColor, activity, snapshot, webView, capture, reader, language
        /// You renamed it (it also sends `.title`).
        case renamed
        /// Its PDF viewer came or went.
        case pdf
        /// Settings came or went over its page.
        case settings
        /// Dark pages began or stopped drawing its page dark (`darkPage`).
        case darkPage
        /// Its developer side changed: it became or stopped being a development tab (`isDevelopment`), or what you
        /// chose for it with the developer tools did (`developer`).
        case developer
        /// The count of its page's errors changed (`pageErrorCount`).
        case pageErrors
    }

    let id: UUID
    /// The space it's in. Changed only through `setSpace`, the one place that can see a tab change profile.
    private(set) var spaceID: UUID
    /// Set when this tab is the live page behind a bookmark. Such tabs live in the bookmark row, not the tab list.
    /// A favorite's page belongs in the favorite's profile, which is known only once this is.
    var bookmarkID: UUID? {
        didSet {
            guard bookmarkID != oldValue else { return }
            if isFavorite { settleProfile() }
            refreshChosenIcon()
        }
    }
    /// Set when this tab is the live page behind a favorite tile.
    var isFavorite = false { didSet { if isFavorite != oldValue { settleProfile() } } }
    /// The tab this one sits under in the list (nested tabs); nil at the top level. Pinned pages and favorites never
    /// have one. TabManager keeps it right (see TabTree).
    var parentID: UUID?
    /// The tabs under this one are folded away in the sidebar.
    var isCollapsed = false

    private(set) var url: URL? { didSet { refreshDevelopment() } }
    private(set) var title: String
    private(set) var favicon: NSImage?
    private(set) var themeColor: NSColor?
    /// What dark pages found on the page (`DarkPages`): whether Zigzag draws it dark, whether it's dark on its own,
    /// and its color as drawn. Nil until a page has been looked at; a page left alone (dark pages off there, a picture
    /// opened on its own) says it isn't darkened.
    private(set) var darkPage: DarkPages.State?
    /// The page's own color, for what's drawn in it around the page: its card's ground and the bar above it. Its
    /// background (a site's theme color can be its header's, and stay light on a page that turned dark), else its
    /// theme color. None with no page, or under what covers it with a color of its own (a PDF, Settings).
    var pageColor: NSColor? {
        guard let webView, pdfViewer == nil, settingsView == nil else { return nil }
        return Self.pageColor(dark: darkPage, under: webView.underPageBackgroundColor, theme: themeColor)
    }

    /// The rule for `pageColor`. A page drawn dark, by Zigzag or on its own, is the dark the page script saw (#134): a
    /// dark site can keep a white theme color for its header, and WebKit's own background under it can be white too,
    /// which painted the bar white over a dark page. That holds with dark pages off too, where the page script only
    /// looks. A dark page whose script found no dark of its own to give (all of it light at the top) gives none.
    /// Otherwise the background under the page, else the theme color.
    static func pageColor(dark: DarkPages.State?, under: NSColor?, theme: NSColor?) -> NSColor? {
        if let dark, let color = dark.color, dark.darkened || (dark.native && DarkPages.isDark(color)) { return color }
        return under ?? theme
    }
    private(set) var isLoading = false
    /// A new page is on its way in (a link followed, an address typed): the one showing is about to go. Until it
    /// arrives (`didCommit`) or never does.
    private(set) var isLeavingPage = false
    private(set) var progress: Double = 0
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var isClosed = false
    /// A PDF shows in Zigzag's own viewer, over WebKit's; nil for any other page.
    private(set) var pdfViewer: PDFViewerView?
    /// The page is a PDF, in either viewer: saved as itself, not as a web archive.
    private(set) var showsPDF = false
    /// The viewer's fetch, cancelled when the viewer goes.
    private var pdfTask: Task<Void, Never>?
    /// PDFs ours couldn't open on this page (a failed fetch, a password): WebKit's viewer stays for them, rather
    /// than ours trying again and flashing its blank over it.
    private var pdfFailed: Set<URL> = []
    /// The main frame's last navigation: anything but Back or Forward builds the viewer again, even for the same
    /// address (Reload); and a form's reply, sent by POST, is never fetched a second time, so WebKit's viewer shows it.
    private var pdfFreshLoad = false
    private var pageIsGet = true
    /// The main frame's last response was a PDF, at this address: known before the page can be asked.
    private var pdfResponseURL: URL?
    /// Settings, over the page while the tab is at zigzag://settings; nil for any other page.
    private(set) var settingsView: SettingsView?
    /// The profile Settings was asked to show before this tab had its page: shown once it has.
    private var settingsProfileAsked: UUID?
    private(set) var isPlayingAudio = false
    private(set) var isMuted = false
    private(set) var hasLoadedOnce = false
    private(set) var snapshot: NSImage?
    var lastActivated: Date
    let createdAt: Date
    /// True for a tab opened by a search from the command bar, until the user leaves the results page.
    var isSearchTab = false
    /// True while the page lives in the peek card rather than the tab list. A PDF in peek is WebKit's; it gets
    /// Zigzag's viewer once it's a tab.
    /// A site installed as an app (`WebAppWindowController`): a link you click to another site goes to the browser.
    var keepsSite = false
    var isPeek = false {
        didSet { if oldValue, !isPeek, let webView { checkForPDF(webView) } }
    }
    /// Set for tabs in a private window: their own throwaway storage, and nothing remembered.
    var privateStore: WKWebsiteDataStore?
    var isPrivate: Bool { privateStore != nil }

    /// Moves it to another space. On another profile, its page moves with it.
    func setSpace(_ id: UUID) {
        spaceID = id
        settleProfile()
    }

    /// Makes sure its page is in its space's profile, rebuilding it there if the space changed profile or the tab
    /// changed space. A private tab's page is in its window's own store, whatever the space.
    func settleProfile() {
        // A private page stays in its window's store; what it's offered (saved logins) is still its space's profile's.
        guard !isPrivate else { profile = Profiles.shared.profile(forSpace: spaceID); return }
        let wanted = homeProfile
        if wanted !== profile { rehome(to: wanted) }
    }

    /// The profile its page belongs in: its space's, or for a favorite, the profile the favorite is kept in,
    /// whichever of that profile's spaces it was last opened from.
    var homeProfile: Profile {
        let favorite = isFavorite ? bookmarkID.flatMap { Library.shared.isFavorite($0) ? $0 : nil } : nil
        return Profiles.shared.profile(Library.shared.directory.profileID(ofPageIn: spaceID, favorite: favorite))
    }

    /// Rebuilds the page in another profile: that profile's sign-ins and extensions, the same back and forward
    /// list. What the page held that wasn't saved (a form half filled in) is lost, as on a reload.
    private func rehome(to new: Profile) {
        let wasLive = webView != nil
        // The profile it leaves hears it close, whether or not its extensions were ever told it opened: they may
        // know it from having listed it.
        if #available(macOS 15.4, *) { ExtensionCenter.tabClosed(self) }
        if let webView {
            pendingInteractionState = webView.interactionState as? Data
            webView.pauseAllMediaPlayback(completionHandler: nil)
            tearDown(webView)
        }
        // A configuration WebKit handed over belongs to the profile of the page that asked for it.
        pendingConfiguration = nil
        profile = new
        if #available(macOS 15.4, *), !isPrivate {
            ExtensionCenter.tabOpened(self)
            if (host as? BrowserWindowController)?.tabManager.selectedTab === self { ExtensionCenter.tabActivated(self, previous: nil) }
        }
        if wasLive { ensureWebView() }
        changed.send(.webView)
    }

    /// The profile its page is made in: its space's. `settleProfile` moves the page when the two come apart.
    private(set) var profile: Profile
    /// The extensions that have been told this tab is open (ExtensionCenter).
    weak var toldTo: ExtensionHost?
    /// Its profile's extensions. None for a private tab: as in Chrome, extensions stay out of private browsing.
    @available(macOS 15.4, *)
    var extensionHost: ExtensionHost? { isPrivate ? nil : profile.extensions }
    /// In a call (camera or microphone on, even muted), floating in Picture in Picture, or playing in the mini
    /// player: not to be put to sleep.
    var isInUse: Bool {
        guard let webView else { return false }
        return isInMiniPlayer || webView.cameraCaptureState != .none || webView.microphoneCaptureState != .none || webView.isPictureInPictureActive
    }
    /// Its video is playing in the window's mini player, its page with it.
    var isInMiniPlayer = false
    /// Its page fills the page's area with something in full screen, as Settings › Tabs › Full screen videos fill
    /// The Page has it (PageFullScreen), so Esc in the window leaves it.
    var isInPageFullScreen = false
    /// What you answered the page's questions (camera, location, notifications) while it's open: asked again once
    /// it loads another page or reloads, as a site set to Ask is.
    var permissionAnswers = PagePermissionAnswers()
    /// From a site you've let send notifications: kept awake and out of the archive, so they keep coming.
    var notifiesUser: Bool {
        guard !isPrivate, let origin = SiteOrigin.of(url) else { return false }
        return SitePermissions.notifications(origin: origin) == true
    }
    /// The tab that opened this one, so closing it can return there.
    weak var opener: Tab? { didSet { opener?.openedHere.add(self) } }
    /// Tabs opened from this one: when it closes, their Back stops offering to return here.
    private let openedHere = NSHashTable<Tab>.weakObjects()
    /// Opened from a link, with nothing earlier in this tab: Back closes it and goes back to the page that opened
    /// it, as Safari and Chrome do.
    var returnsToOpener: Bool {
        guard !canGoBack, !isPeek, bookmarkID == nil, let opener, !opener.isClosed else { return false }
        // Dragged into another window, the page it came from is no longer beside it.
        return opener.spaceID == spaceID && opener.host === host
    }
    var canGoBackOrReturn: Bool { canGoBack || returnsToOpener }

    weak var host: TabHost?
    /// When its page last stopped unexpectedly, to tell a one-off from a page that keeps stopping.
    private var crashes: [Date] = []
    private var reloadWhenShown = false
    /// Why its page last stopped, until it has loaded again and that's been said.
    private var stoppedFor: PageStop?
    /// Where you were on the page and what you'd typed, read as you left it; it stays while the tab is out of sight.
    private(set) var pageState: PageState?
    /// The page is loading again after it slept or stopped: once it's here, `pageState` puts it back.
    private var restoresPageState = false
    /// The host whose certificate warning this tab last showed: the only one its "Visit anyway" link may trust.
    private var certificateWarningHost: String?
    /// The certificate that warning was about: the one "Visit anyway" trusts.
    private var certificateWarningCertificate: Data?
    /// The nonce written into that warning's "Visit anyway" link, new for each warning.
    private var certificateWarningNonce: String?
    let changed = Signal<Change>()

    /// The page showing came with a certificate you chose to trust on the warning page ("Visit anyway"): the
    /// connection is not secure, and the address and Site Controls say so for as long as it's in use.
    var usesCertificateException: Bool {
        guard let webView, let url = webView.url, url.scheme?.lowercased() == "https", let host = url.host(),
              let trust = webView.serverTrust else { return false }
        return CertificateExceptions.allows(host, trust: trust, in: webView.configuration.websiteDataStore)
    }

    #if DEBUG
    /// visitanyway: what the warning's "Visit anyway" does, for a test copy whose clicks don't reach the page. Only
    /// while this tab shows a warning that offers it, for that warning's certificate.
    func debugVisitAnyway() {
        guard let webView, let host = certificateWarningHost, certificateWarningNonce != nil, let url = webView.url,
              url.host()?.lowercased() == host,
              CertificateExceptions.allow(host, certificate: certificateWarningCertificate, in: webView.configuration.websiteDataStore) else { return }
        certificateWarningHost = nil
        certificateWarningNonce = nil
        load(url)
    }
    #endif

    /// The page isn't secure: plain http, or a certificate let through on the warning page.
    var isNotSecure: Bool { url?.scheme?.lowercased() == "http" || usesCertificateException }

    private(set) var webView: BrowserWebView?
    /// Where the web view sits, with the Web Inspector when it's docked (`PageHolder`): what shows the tab borrows this,
    /// never the web view alone. Made with the first web view and kept, so the next one appears in its place.
    private(set) var pageHolder: PageHolder?
    /// Back/forward history and scroll position kept while suspended or across launches.
    private var pendingInteractionState: Data?
    private var pendingConfiguration: WKWebViewConfiguration?
    private var observations: [NSKeyValueObservation] = []
    private var observingAudio = false

    init(id: UUID = UUID(), url: URL?, title: String? = nil, spaceID: UUID, configuration: WKWebViewConfiguration? = nil,
         interactionState: Data? = nil, lastActivated: Date = Date(), createdAt: Date = Date()) {
        self.id = id
        // A web view WebKit made for a page's new window shows no address until its first page arrives: the page
        // that opened it can write into it while a load that never finishes would name another site over it.
        self.url = configuration == nil ? url : nil
        self.title = title ?? (SettingsPage.isSettings(self.url) ? String(localized: "Settings", comment: "The name of the tab showing Zigzag's Settings.") : self.url?.host() ?? String(localized: "New Tab", comment: "The name of a tab with no page yet."))
        self.spaceID = spaceID
        // A page WebKit made for another page's new window is in that page's profile, whatever space it lands in.
        self.profile = configuration.flatMap { Profiles.shared.profile(ofStore: $0.websiteDataStore) } ?? Profiles.shared.profile(forSpace: spaceID)
        self.pendingConfiguration = configuration
        self.pendingInteractionState = interactionState
        self.lastActivated = lastActivated
        self.createdAt = createdAt
        super.init()
        if let url = self.url { favicon = FaviconStore.shared.cachedIcon(for: url) }
        isDevelopment = DeveloperTools.applies(to: self.url)
        snapshot = SnapshotStore.load(id)
        if #available(macOS 15.4, *) {
            extensionToken = changed.observe { [weak self] change in
                guard let self else { return }
                ExtensionCenter.tabChanged(self, change)
            }
        }
    }

    private var extensionToken: SignalToken?

    /// Its page is running: a web view is there. Not while it sleeps, nor for a tab restored after a relaunch until
    /// it's shown or something loads it. What every place that draws a tab tells "not running" from (#205).
    var isLoaded: Bool { webView != nil }
    var isSuspended: Bool { !isLoaded }
    /// Came back with the session after a relaunch and hasn't loaded since: its hover card says so, rather than
    /// that it was put to sleep.
    var isRestored = false
    /// Why its page isn't running, for its hover card or a favorite's tooltip; nil while it is. Only a tab put to
    /// sleep tells of memory it freed.
    var notLoadedNote: String? {
        guard !isLoaded else { return nil }
        if let asleepNote { return asleepNote }
        return isRestored
            ? String(localized: "Not loaded since Zigzag reopened. Loads when you click it.", comment: "Under a tab's title in its hover card, or a favorite's tooltip: the tab came back after Zigzag was quit and opened again, and its page loads only once you click it.")
            : String(localized: "Not loaded yet. Loads when you click it.", comment: "Under a tab's title in its hover card, or a favorite's tooltip: the tab's page hasn't loaded yet and loads once you click it.")
    }
    /// Put to sleep this run (not merely not loaded yet after a relaunch), and whether it was for using a lot of energy:
    /// the sidebar marks it, so a tab never seems to have lost its page for no reason.
    private(set) var isAsleep = false
    private(set) var sleptForEnergy = false
    /// About how much memory its page gave back as it slept (`SleepMemory.share`), for the hover card; nil awake.
    private(set) var freedMemory: UInt64?
    /// What the sidebar says of it while it sleeps, nil awake.
    var asleepNote: String? { isAsleep ? SleepMemory.note(forEnergy: sleptForEnergy, freed: freedMemory) : nil }
    /// A name you gave the tab (double-click to rename); it stays whatever the page calls itself.
    /// While a pinned page is first loading, where it ends up on its own (a site that redirects, like
    /// calendar.google.com) counts as the pinned page, so it's never "moved on" before you've done anything.
    var landingUntil: Date?
    var pinnedLanding: URL?
    var customTitle: String? { didSet { if oldValue != customTitle { changed.send(.title); changed.send(.renamed) } } }
    /// An icon you gave the tab (an SF Symbol's name, or an emoji), drawn instead of its site's. The page of a pinned
    /// tab or a favorite shows that one's icon instead (`chosenIcon`).
    var customIcon: String? { didSet { if oldValue != customIcon { refreshChosenIcon() } } }
    /// The icon you chose that stands for it, or nil for its site's. Kept up to date (`refreshChosenIcon`), and
    /// says `.favicon` when it changes, as a new site icon does.
    private(set) var chosenIcon: String?

    /// A development tab (#141): Developer tools is on and the page it shows is on a site you develop
    /// (`DevelopmentSites`). The page it shows is the one last committed; before any, the address it's going to, so
    /// a new tab on its way to localhost and one restored asleep are told too. An address shown early, for a page
    /// that hasn't come, changes nothing: a sign-in that passes through another site doesn't flicker it.
    private(set) var isDevelopment = false

    /// Looks again at whether it's a development tab: its page changed, or Settings › Developer did.
    /// `settingsChanged`: the page is the one it was, so what it was told and allowed as it loaded (its user agent,
    /// its scripts) only follows once it loads again.
    func refreshDevelopment(settingsChanged: Bool = false) {
        let now = DeveloperTools.applies(to: committedURL ?? url)
        guard now != isDevelopment else { return }
        isDevelopment = now
        if !now { pageErrorCount = 0 }
        if let webView { PageErrors.counts(in: webView, now) }
        // Its choices come into effect with it, and are lifted with it.
        if !developer.isUnchanged { applyDeveloperState(); applyDeveloperStateToPage() }
        changed.send(.developer)
        if settingsChanged, developer.needsReload(from: DeveloperState()) { reload() }
    }

    /// What you chose for this tab with the developer tools (`DeveloperState`). Read through `developerInEffect`.
    /// The last size the page had with the developer tools, for Toggle Page Size to give it again.
    private(set) var developerLastSize: CGSize?

    var developer = DeveloperState() {
        didSet {
            guard developer != oldValue else { return }
            if let size = developer.size { developerLastSize = size }
            applyDeveloperState()
            applyDeveloperStateToPage()
            // What a page is told and allowed as it loads shows once it has loaded again.
            if isDevelopment, developer.needsReload(from: oldValue) { reload() }
            changed.send(.developer)
        }
    }

    /// A development tab's uncaught errors and failed promises since its page came, in every frame of it
    /// (`PageErrors`), for the count on the console's button. Nothing is counted on any other tab.
    private(set) var pageErrorCount = 0

    /// The page threw `count` more errors.
    func countPageErrors(_ count: Int) {
        guard isDevelopment, count > 0 else { return }
        pageErrorCount += count
        changed.send(.pageErrors)
    }

    /// A new page, or none: its errors went with the last one.
    private func forgetPageErrors() {
        guard pageErrorCount != 0 else { return }
        pageErrorCount = 0
        changed.send(.pageErrors)
    }

    /// Looks again at which chosen icon shows: after its own changes, it becomes or stops being a pinned page's or a
    /// favorite's, or the library changes (that page given an icon, or ⌘Z taking one back).
    func refreshChosenIcon() {
        let icon = Self.chosenIcon(own: customIcon, bookmarkID: bookmarkID) { Library.shared.bookmark($0) }
        guard icon != chosenIcon else { return }
        chosenIcon = icon
        changed.send(.favicon)
    }

    /// A pinned page's or favorite's page shows the icon given to that page, or its site's if it has none, whatever
    /// the tab had of its own; any other tab shows its own.
    static func chosenIcon(own: String?, bookmarkID: UUID?, bookmark: (UUID) -> Bookmark?) -> String? {
        guard let bookmarkID else { return own }
        return bookmark(bookmarkID)?.icon
    }

    /// What stands for the tab wherever it's drawn (its row, a favorite's tile, the switcher, the command bar): the
    /// icon you chose, else its site's.
    var displayIcon: NSImage? { Self.displayIcon(chosen: chosenIcon, favicon: favicon) }

    static func displayIcon(chosen: String?, favicon: NSImage?) -> NSImage? { chosen.map(IconChoice.pageIcon) ?? favicon }

    var displayTitle: String {
        if let customTitle, !customTitle.isEmpty { return customTitle }
        // Zigzag's own pages go by their names wherever the chrome names them.
        if SettingsPage.isSettings(url) { return String(localized: "Settings", comment: "The name of the tab showing Zigzag's Settings.") }
        if HistoryPage.isHistory(url) { return String(localized: "History", comment: "The name of the tab showing Zigzag's History.") }
        if !title.isEmpty { return title }
        // A file on your Mac, or a PDF from the web, is called by its name: it has no title of its own.
        if let url, url.isFileURL || url.pathExtension.lowercased() == "pdf", !url.lastPathComponent.isEmpty, url.lastPathComponent != "/" {
            return url.lastPathComponent
        }
        return url?.host() ?? String(localized: "New Tab", comment: "The name of a tab with no page yet.")
    }
    var isBlank: Bool { url == nil }

    // MARK: Web view lifecycle

    /// Returns the live web view, creating or restoring it if needed.
    @discardableResult
    func ensureWebView() -> BrowserWebView {
        if let webView { return webView }
        isAsleep = false
        isRestored = false
        sleptForEnergy = false
        freedMemory = nil
        let fromWebKit = pendingConfiguration != nil
        let extensionConfiguration = fromWebKit ? nil : Self.extensionConfiguration(for: url, in: profile)
        let configuration = pendingConfiguration ?? extensionConfiguration ?? WebKitSetup.makeConfiguration(for: profile)
        pendingConfiguration = nil
        if extensionConfiguration != nil {
            configuration.applicationNameForUserAgent = WebKitSetup.applicationNameForUserAgent
        } else if !fromWebKit {
            WebKitSetup.configure(configuration, for: profile)
            WebNotifications.attach(to: configuration, isPrivate: privateStore != nil)
            Passkeys.attach(to: configuration, isPrivate: privateStore != nil, profile: profile)
            HistoryPage.attach(to: configuration)
            if let privateStore {
                configuration.websiteDataStore = privateStore
                // Extensions stay out of private browsing, as in Chrome: they can't read or change these pages.
                if #available(macOS 15.4, *) { configuration.webExtensionController = nil }
            }
        }
        // Extensions' user scripts (BridgeUserScripts), in a page WebKit opened for another too. Private pages, and
        // extensions' own pages, run none.
        if #available(macOS 15.4, *), extensionConfiguration == nil, privateStore == nil,
           configuration.webExtensionController === profile.extensions.controller {
            profile.extensions.bridge.userScripts.attach(configuration.userContentController)
        }
        showsExtensionPage = extensionConfiguration != nil
        openedByPage = fromWebKit
        if Self.isExtensionPage(url) { ExtensionPageErrors.attach(to: configuration) }
        #if DEBUG
        if DebugBridge.mutesEverything {
            configuration.mediaTypesRequiringUserActionForPlayback = .all
            configuration.userContentController.addUserScript(WKUserScript(source: Self.elementMuting(true), injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .defaultClient))
        }
        // ZIGZAG_PAGE_PROBE=<file>: a script of your own put into each page as it starts, after Zigzag's, to watch
        // what a page does or stage what a site does in a test copy.
        if let probe = ProcessInfo.processInfo.environment["ZIGZAG_PAGE_PROBE"], let source = try? String(contentsOfFile: probe, encoding: .utf8) {
            configuration.userContentController.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        }
        #endif

        let webView = BrowserWebView(frame: NSRect(origin: .zero, size: Tokens.Metric.windowDefaultSize), configuration: configuration)
        webView.owner = self
        webView.navigationDelegate = self
        webView.uiDelegate = self
        // Back and forward by swiping is ours (SwipeNavigator): quicker than WebKit's sliding page.
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsMagnification = true
        webView.isInspectable = true
        Self.stopsAutomaticInsets(webView)
        #if DEBUG
        // Lets scripted screenshots capture pages while the window is behind other apps.
        let occlusion = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        if webView.responds(to: occlusion) {
            typealias SetBool = @convention(c) (AnyObject, Selector, Bool) -> Void
            unsafeBitCast(webView.method(for: occlusion), to: SetBool.self)(webView, occlusion, false)
        }
        #endif
        #if DEBUG
        if DebugBridge.mutesEverything { isMuted = webView.setPageAudioMuted(true) ?? true }
        #endif
        self.webView = webView
        if let pageHolder { pageHolder.hold(webView) } else { pageHolder = PageHolder(holding: webView) }
        observe(webView)
        DarkPages.attach(to: webView)
        PageFullScreen.attach(to: webView)
        // What you chose for this tab with the developer tools comes with a new web view, before its first page is
        // asked for: it's asked for as the browser chosen, and starts with the look chosen.
        if !developer.isUnchanged { applyDeveloperState() }

        if Self.isExtensionPage(url), let url {
            // Extension pages always load fresh: their saved history state can come back as a blank page, and one
            // from an extension that's gone gets explained rather than restored.
            pendingInteractionState = nil
            loadOwn(url, in: webView)
        } else if let state = pendingInteractionState {
            restoreState(state, in: webView)
            pendingInteractionState = nil
            restoresPageState = pageState?.belongs(to: webView.url ?? url) == true
            // Interaction state restores history but may not start a load on its own.
            if webView.url == nil, let url { loadOwn(url, in: webView) }
        } else if let url, !fromWebKit {
            loadFirst(url, in: webView)
        }
        // A new web view starts with sound and playing; carry over what you'd set on the old one.
        if isMuted { setMuted(true) }
        // A development tab's pages are listened to for the count of their errors.
        if isDevelopment { PageErrors.counts(in: webView, true) }
        isPlaybackPaused = false
        refreshSettingsPage()
        changed.send(.webView)
        return webView
    }

    /// Releases the web view but keeps everything needed to bring it back. Not while something you typed is in it.
    /// `because`: why, for Help › Report a Problem.
    func suspend(because reason: String? = nil) {
        guard let webView, !isPlayingAudio, !isInMiniPlayer else { return }
        sleepTicket += 1
        let ticket = sleepTicket
        readPageState { [weak self] state in self?.sleep(webView, ticket: ticket, state: state, because: reason) }
        // A page stuck in a loop (what EnergyWatch sleeps) never answers: what was read as you left it decides.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            MainActor.assumeIsolated { self?.sleep(webView, ticket: ticket, state: self?.pageState, because: reason) }
        }
    }

    /// The asking for `suspend` still waiting, so whichever of the page's answer and the wait for it comes first decides.
    private var sleepTicket = 0

    private func sleep(_ webView: BrowserWebView, ticket: Int, state: PageState?, because reason: String?) {
        guard sleepTicket == ticket, self.webView === webView else { return }
        sleepTicket += 1
        guard state?.hasTypedText != true else { return }
        captureSnapshot { [weak self] in
            guard let self, self.webView === webView else { return }
            self.pendingInteractionState = webView.interactionState as? Data
            let freed = self.memoryInUse(by: webView)
            self.tearDown(webView)
            self.freedMemory = freed
            self.isAsleep = true
            self.sleptForEnergy = reason == EnergyWatch.sleepReason
            self.changed.send(.webView)
            if let reason { Diagnostics.note("Tab put to sleep", site: self.url?.host(), reason, isPrivate: self.isPrivate) }
        }
    }

    /// Its share of its page process's memory, as it goes to sleep: the process's footprint over the tabs awake in it.
    private func memoryInUse(by webView: BrowserWebView) -> UInt64? {
        guard let pid = EnergyWatch.processID(of: webView), pid > 0 else { return nil }
        let sharing = WindowManager.shared.controllers.flatMap(\.tabManager.allTabs).filter { tab in
            tab.webView.flatMap(EnergyWatch.processID) == pid
        }.count
        return SleepMemory.share(footprint: ProcessMemory.footprint(pid), tabsSharing: sharing)
    }

    /// Reads where you are on the page and what you've typed (`pageState`), as you leave it and before it sleeps.
    func readPageState(_ completion: ((PageState?) -> Void)? = nil) {
        guard let webView, hasLoadedOnce, !Self.isExtensionPage(url), pdfViewer == nil, settingsView == nil else { completion?(pageState); return }
        webView.evaluateJavaScript(PageState.reader, in: nil, in: .defaultClient) { [weak self, weak webView] result in
            guard let self, let webView, self.webView === webView else { completion?(nil); return }
            // A page that won't say (still loading, or its process gone) keeps what was read before.
            if case .success(let value) = result, let state = PageState(value, url: webView.url) { self.pageState = state }
            completion?(self.pageState)
        }
    }

    /// The page script said what it found. Whatever colors itself after the page (the bar above it) hears of it as
    /// `.darkPage`, and as `DarkPages.pageDarkenedNotification`.
    func darkPageChanged(_ state: DarkPages.State) {
        guard state != darkPage else { return }
        let wasDarkened = darkPage?.darkened ?? false
        darkPage = state
        changed.send(.darkPage)
        if state.darkened != wasDarkened { NotificationCenter.default.post(name: DarkPages.pageDarkenedNotification, object: self) }
    }

    /// Shown again: unless its page is loading back, what was read as you left it isn't needed.
    func shown() {
        if !restoresPageState { pageState = nil }
    }

    private func restorePageState(in webView: WKWebView) {
        guard restoresPageState else { return }
        restoresPageState = false
        defer { pageState = nil }
        guard let state = pageState, state.belongs(to: webView.url) else { return }
        webView.callAsyncJavaScript(PageState.restorer, arguments: state.restoreArguments, in: nil, in: .defaultClient) { _ in }
    }

    /// `keepingSnapshot`: its window closed but the tab may come back (reopening the last window), so its
    /// thumbnail stays until the next save prunes what isn't kept.
    func close(keepingSnapshot: Bool = false) {
        isClosed = true
        pageState = nil
        for tab in openedHere.allObjects where !tab.canGoBack { tab.changed.send(.navigation) }
        // Sound stops the moment it closes, whatever may still hold the page for a moment.
        webView?.pauseAllMediaPlayback(completionHandler: nil)
        if let webView { tearDown(webView) }
        // Its holder leaves whatever was showing it (the page card, Peek, a card it stayed in during a video's full
        // screen), as its page does.
        pageHolder?.removeFromSuperview()
        if !keepingSnapshot {
            SnapshotStore.remove(id)
            // Undo steps can hold a closed tab for a while; its picture (megabytes, on a Retina screen) needn't.
            snapshot = nil
        }
    }

    private func tearDown(_ webView: BrowserWebView) {
        Autofill.shared.forget(webView)
        setPDFViewer(nil)
        if settingsView != nil {
            settingsView = nil
            changed.send(.settings)
        }
        PageDialogSheet.cancel(for: webView)
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
        isLeavingPage = false
        isPlayingAudio = false
        forgetPageErrors()
    }

    /// History snapshot for session restore. Cheap when the web view is suspended.
    /// Went somewhere since the session was last saved, so its back/forward data has to be encoded again.
    var navigatedSinceSave = true
    /// Scrolled, clicked or typed in since the session was last saved: where you are on the page is in its
    /// back/forward data too.
    var scrolledSinceSave = false

    var interactionStateForSaving: Data? {
        if let webView { return webView.interactionState as? Data }
        return pendingInteractionState
    }

    // MARK: Navigation

    /// Another page: what was known of the one before (its language, that it's shown translated) goes with it.
    /// Called before the tab takes the new address, wherever it does, so a page you typed in isn't still taken
    /// as translated (#197).
    private func leavePage(for url: URL) {
        guard url != self.url, foreignLanguage != nil || isTranslated else { return }
        foreignLanguage = nil
        isTranslated = false
        changed.send(.language)
    }

    func load(_ url: URL, by sender: LoadSender = .zigzag) {
        leavePage(for: url)
        // Extension pages and websites need differently set up web views; crossing over swaps it.
        if let webView, Self.isExtensionPage(url) != showsExtensionPage {
            self.url = url
            changed.send(.url)
            tearDown(webView)
            ensureWebView()
            return
        }
        // The page that opened this tab can still write into the one showing: the address waits for the new page.
        // So does one a page asked for: it shows once it arrives, as any page's own navigation does.
        if webView == nil || (!openedByPage && sender != .page) {
            self.url = url
            changed.send(.url)
        }
        let webView = ensureWebView()
        load(url, in: webView, by: sender)
        refreshSettingsPage()
    }

    /// Who sent a tab to an address. Only you can let a link open another app without asking, and only Zigzag (you
    /// included) can take a tab to one of its own pages or show the address before the page arrives.
    enum LoadSender {
        /// Typed in the address bar or chosen from the command bar.
        case you
        /// Zigzag itself: a bookmark, a restored tab, an extension or an agent asking through Zigzag.
        case zigzag
        /// A page: its window.open(), a link it opened in a new tab or a card, a link in its article or PDF.
        case page
    }

    /// What a page may send a tab to on its own: only the web. An app's link goes to ExternalLinks, which asks (and
    /// holds to the site's Block); a file on your Mac, a script address, an extension's page or one of Zigzag's own
    /// is refused, except a local page linking to another file beside it.
    enum PageLinkRoute: Equatable { case load, app, refuse }

    static func route(forPageLink url: URL, from page: URL?) -> PageLinkRoute {
        let scheme = url.scheme?.lowercased() ?? ""
        if ["http", "https", "about", "data", "blob"].contains(scheme) { return .load }
        if scheme == "file" { return page?.isFileURL == true ? .load : .refuse }
        if scheme.isEmpty || ["javascript", "webkit-extension", HistoryPage.scheme].contains(scheme) { return .refuse }
        return .app
    }

    /// Goes where a page asked this tab to go (its window.open() into a card or a web app's window): as the page's
    /// doing, never Zigzag's or yours. An app's link asks first, from this page; anything else not on the web goes nowhere.
    func openFromPage(_ url: URL, isClick: Bool, asker: WKSecurityOrigin?) {
        switch Self.route(forPageLink: url, from: self.url) {
        case .load:
            load(url, by: .page)
        case .app:
            guard let webView else { return }
            ExternalLinks.open(url, isMainFrame: true, isClick: isClick, linkClick: false, from: webView, asker: asker, byYou: false)
        case .refuse:
            Diagnostics.note("Refused a page's link", site: self.url?.host(), "\(url.scheme ?? "no scheme"):", isPrivate: isPrivate)
        }
    }

    /// The page looks like an article, so Reader is offered.
    private(set) var isArticle = false
    /// The page's language, when it isn't the reader's and can be translated.
    private(set) var foreignLanguage: Locale.Language?
    /// Which language check is the current one: one for a page since left changes nothing.
    fileprivate var languageCheck = 0
    /// The page's text is shown translated.
    var isTranslated = false

    /// True while the web view was built for an extension's own pages (settings, dashboards).
    private var showsExtensionPage = false
    /// A navigation the page started is on its way: its address waits until it commits (see followAddress).
    private var addressWaitsForCommit = false
    /// Its web view was made by WebKit for a page's new window, so that page (its opener) can script it: every
    /// address it goes to waits until it commits, Zigzag's own loads too.
    private var openedByPage = false
    /// Zigzag itself is loading this tab (the address bar, a link from elsewhere): its address shows at once. `.you`
    /// when you typed or chose it, so an app's link opens without asking. Never `.page`: a page's own load is nil.
    private var ownLoadPending: LoadSender?
    /// Who the address this tab was made with came from, for its first load (a link a page opened in a new tab).
    var firstLoadSender: LoadSender = .zigzag
    /// Where Zigzag itself is taking this tab back or forward (its buttons, a swipe, the keyboard, restored history):
    /// the only Back or Forward that may land on one of Zigzag's own pages. A page's history.back() may not.
    private var ownHistoryTarget: URL?
    /// When the page last started a download without a click, and when a frame in it was last clicked into.
    private var lastScriptDownload: Date?
    private var frameClickedAt: Date?

    static func isExtensionPage(_ url: URL?) -> Bool { url?.scheme == "webkit-extension" }

    /// What a page may open in a new window or tab (window.open, target=_blank, Open Link in New Tab): anything but
    /// Zigzag's own pages, which open from Zigzag.
    static func mayOpenInNewWebView(_ url: URL?) -> Bool { url?.scheme?.lowercased() != HistoryPage.scheme }

    /// WebKit shows an extension's pages only in a web view set up by that extension.
    private static func extensionConfiguration(for url: URL?, in profile: Profile) -> WKWebViewConfiguration? {
        guard #available(macOS 15.4, *) else { return nil }
        return profile.extensions.context(forPage: url)?.webViewConfiguration
    }

    /// The profile a page is in: its tab's, or for a page that isn't a tab's (a pop-up window), the one it was made in.
    private static func profile(of webView: WKWebView) -> Profile {
        Profiles.shared.profile(ofPage: webView)
    }

    /// Starts this tab with another tab's back/forward list, then navigates: used for search folding.
    func restoreHistory(_ state: Data, thenLoad url: URL, by sender: LoadSender = .zigzag) {
        if let webView {
            restoreState(state, in: webView)
        } else {
            pendingInteractionState = state
        }
        let webView = ensureWebView()
        leavePage(for: url)
        self.url = url
        changed.send(.url)
        load(url, in: webView, by: sender)
    }

    /// Gives a new tab another's back and forward history (Duplicate).
    func restoreState(_ state: Data) {
        restoreState(state, in: ensureWebView())
    }

    /// Restoring history goes to the page it was on, as Zigzag's own Back or Forward would: Settings comes back too.
    private func restoreState(_ state: Data, in webView: WKWebView) {
        webView.interactionState = state as NSData
        ownHistoryTarget = webView.backForwardList.currentItem?.url ?? url
    }

    /// Loads a page in this tab's web view as Zigzag's own doing (not the page's), so its address shows at once.
    private func loadOwn(_ url: URL, in webView: WKWebView) {
        load(url, in: webView, by: .zigzag)
    }

    /// Loads a page in this tab's web view for `sender`: only Zigzag's own loads, and yours, count as its own.
    private func load(_ url: URL, in webView: WKWebView, by sender: LoadSender) {
        ownLoadPending = sender == .page ? nil : sender
        Self.load(url, in: webView)
    }

    /// The first load of a tab made with an address, as whoever gave it.
    private func loadFirst(_ url: URL, in webView: WKWebView) {
        let sender = firstLoadSender
        firstLoadSender = .zigzag
        load(url, in: webView, by: sender)
    }

    /// Local files need read access granted to their folder; everything else is a plain request.
    static func load(_ url: URL, in webView: WKWebView) {
        // WebKit quietly ignores a page from an extension it doesn't have; say what happened instead.
        let profile = Self.profile(of: webView)
        if isExtensionPage(url), extensionConfiguration(for: url, in: profile) == nil {
            // Opened by an extension that's still loading (1Password's welcome page, right after it installs):
            // wait for it, briefly, before saying the page is unavailable.
            if #available(macOS 15.4, *) {
                var token: SignalToken?
                var waited = false
                token = profile.extensions.changed.observe { [weak webView] in
                    guard let webView, !waited, extensionConfiguration(for: url, in: profile) != nil else { return }
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
            webView.loadFileURL(url, allowingReadAccessTo: Self.readAccess(for: url))
        } else {
            webView.load(URLRequest(url: url))
        }
    }

    /// What a local page may read: its folder, for its pictures and styles beside it. Not when it sits loose in
    /// Downloads, or the folder Settings saves downloads to, which hold everything you've ever downloaded: there
    /// only the file, unless it was saved as a whole page with its "_files" folder.
    static func readAccess(for file: URL, downloadFolders: [URL] = Tab.downloadFolders) -> URL {
        let folder = file.deletingLastPathComponent()
        let path = folder.resolvingSymlinksInPath().standardizedFileURL.path
        guard downloadFolders.contains(where: { $0.resolvingSymlinksInPath().standardizedFileURL.path == path }) else { return folder }
        let saved = folder.appendingPathComponent(file.deletingPathExtension().lastPathComponent + "_files")
        return FileManager.default.fileExists(atPath: saved.path) ? folder : file
    }

    /// Where downloads land: Downloads, and the folder chosen in Settings if it's another.
    static var downloadFolders: [URL] {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask) + [DownloadManager.folder]
    }

    /// Takes the web view's address as the tab's: the page shown now, or one Zigzag itself is loading.
    private func followAddress(of wv: WKWebView) {
        guard let url = wv.url else { return }
        let hostChanged = url.host() != self.url?.host()
        if url != self.url, self.isArticle { self.isArticle = false; self.changed.send(.reader) }
        leavePage(for: url)
        let changedPage = url != self.url
        self.url = url
        self.navigatedSinceSave = true
        // A page that changes its address without loading (YouTube, GitHub, Gmail) goes in history too.
        if changedPage, !wv.isLoading { self.recordHistory(url, title: nil) }
        // Its language too, once the new page has drawn: it never finishes loading to be read then (#218).
        if changedPage, !wv.isLoading { self.checkLanguage(of: wv, after: 1.5) }
        // Another site: never the last site's icon. Its own if it's known, otherwise none until the page offers one.
        if hostChanged {
            self.favicon = FaviconStore.shared.cachedIcon(for: url)
            self.changed.send(.favicon)
            if self.favicon == nil { self.refreshFavicon() }
        }
        self.changed.send(.url)
        self.refreshSettingsPage()
    }

    func goBack() {
        if canGoBack {
            ownHistoryTarget = webView?.backForwardList.backItem?.url
            webView?.goBack()
        } else if returnsToOpener { host?.tabWantsToReturnToOpener(self) }
    }
    func goForward() {
        ownHistoryTarget = webView?.backForwardList.forwardItem?.url
        webView?.goForward()
    }
    /// A page from the Back or Forward button's menu.
    func go(to item: WKBackForwardListItem) {
        ownHistoryTarget = item.url
        webView?.go(to: item)
    }
    func reload() {
        guard let webView else { ensureWebView(); return }
        if webView.url == nil, let url { loadOwn(url, in: webView) } else { webView.reload() }
    }
    func reloadFromOrigin() { webView?.reloadFromOrigin() }
    func stopLoading() { webView?.stopLoading() }

    func markActivated() {
        lastActivated = Date()
        changed.send(.activity)
    }

    // MARK: Audio

    /// Mutes or unmutes everything the page plays. A sleeping tab remembers it for when its page loads again. What
    /// shows (the speaker, the menu's Mute or Unmute) is what WebKit says the page is now, not only what was asked.
    func setMuted(_ muted: Bool) {
        if let webView {
            if let now = webView.setPageAudioMuted(muted) {
                isMuted = now
            } else {
                // No page muting in this WebKit: each sound the page plays, now and later, is muted instead.
                webView.evaluateJavaScript(Self.elementMuting(muted))
                isMuted = muted
            }
        } else {
            isMuted = muted
        }
        changed.send(.audio)
    }

    private static let setAutomaticInsets = NSSelectorFromString("_setAutomaticallyAdjustsContentInsets:")

    /// The page is placed under Zigzag's own bars, never under the window's title bar, so WebKit isn't to inset it for
    /// one (#204). Left to adjust itself, it insets the page by the title bar it finds above it, as it does in its
    /// own full screen window, where the page is first laid out with a band along its top. Not public API, so only
    /// where WebKit has it.
    static func stopsAutomaticInsets(_ webView: WKWebView) {
        guard webView.responds(to: setAutomaticInsets) else { return }
        typealias SetBool = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(webView.method(for: setAutomaticInsets), to: SetBool.self)(webView, setAutomaticInsets, false)
    }

    /// Mutes (or unmutes) the page's audio and video, and any it plays later, where WebKit can't mute the page.
    static func elementMuting(_ muted: Bool) -> String {
        """
        (() => {
          window.__zigzagMuted = \(muted);
          document.querySelectorAll('audio,video').forEach(m => m.muted = \(muted));
          if (window.__zigzagMuteWatch) return;
          window.__zigzagMuteWatch = true;
          document.addEventListener('play', (e) => { if (window.__zigzagMuted && e.target instanceof HTMLMediaElement) e.target.muted = true; }, true);
        })()
        """
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

    /// Retakes the page's picture. `keep: false` only refreshes it in memory (a preview being watched, every second)
    /// and leaves the disk alone until `keepSnapshot()`.
    func captureSnapshot(keep: Bool = true, _ completion: (() -> Void)? = nil) {
        guard let webView, webView.window != nil, webView.bounds.width > 0, hasLoadedOnce else { completion?(); return }
        // A PDF's picture is of Zigzag's viewer, as you see it (dark pages and all), not WebKit's underneath.
        // Settings likewise: the picture is of what covers the page, not the empty page under it.
        if let image = pdfViewer.flatMap({ $0.window != nil ? $0.snapshot() : nil }) ?? settingsView.flatMap({ $0.window != nil ? $0.snapshot() : nil }) {
            snapshot = image
            if keep, !isPrivate { SnapshotStore.save(image, for: id) }
            changed.send(.snapshot)
            completion?()
            return
        }
        let config = WKSnapshotConfiguration()
        config.afterScreenUpdates = false
        config.snapshotWidth = NSNumber(value: Double(min(webView.bounds.width, 1280)))
        webView.takeSnapshot(with: config) { [weak self] image, _ in
            guard let self else { return }
            if let image {
                self.snapshot = image
                if keep, !self.isPrivate { SnapshotStore.save(image, for: self.id) }
                self.changed.send(.snapshot)
            }
            completion?()
        }
    }

    /// A page that has only ever loaded out of sight (opened in the background) has no picture: WebKit draws it
    /// only in a window. Its holder is put in `host` for a moment, at `size`, under everything else, to be drawn and
    /// pictured, then let go, unless something else took it meanwhile (you went to its tab).
    func captureSnapshotOutOfSight(in host: NSView, size: NSSize, _ completion: @escaping () -> Void) {
        guard let webView, let holder = pageHolder, webView.superview === holder, webView.window == nil, hasLoadedOnce,
              host.window != nil, size.width > 0, size.height > 0 else {
            completion()
            return
        }
        let resizing = holder.autoresizingMask
        holder.autoresizingMask = []
        holder.frame = NSRect(origin: .zero, size: size)
        host.addSubview(holder)
        let letGo = { [weak holder, weak host] in
            guard let holder, let host, holder.superview === host else { return }
            holder.removeFromSuperview()
            holder.autoresizingMask = resizing
        }
        let config = WKSnapshotConfiguration()
        config.afterScreenUpdates = true
        config.snapshotWidth = NSNumber(value: Double(min(size.width, 1280)))
        // A moment in the window first, for it to draw.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self, weak webView] in
            guard let self, let webView, webView.window != nil else { letGo(); completion(); return }
            webView.takeSnapshot(with: config) { [weak self] image, _ in
                letGo()
                if let self, let image, !TabThumbnailView.isBlank(image) {
                    self.snapshot = image
                    if !self.isPrivate { SnapshotStore.save(image, for: self.id) }
                    self.changed.send(.snapshot)
                }
                completion()
            }
        }
    }

    /// Whether the overview should picture a page out of sight: it has a live page that's loaded, it isn't on
    /// screen, and it has no picture yet.
    nonisolated static func needsPictureOutOfSight(hasWebView: Bool, onScreen: Bool, loaded: Bool, hasPicture: Bool) -> Bool {
        hasWebView && !onScreen && loaded && !hasPicture
    }

    /// Saves the picture last taken in memory only, so it's there after a relaunch.
    func keepSnapshot() {
        if let snapshot, !isPrivate { SnapshotStore.save(snapshot, for: id) }
    }

    /// The address last written to history, so a load and its address change count as one visit.
    private var lastRecorded: URL?
    /// The address an error page is showing for ("Can't find…"): not a visit, so not history or a suggestion.
    private var errorShownFor: URL?
    /// Only showing an error page ("Can't find…") for where it tried to go: there's no page to go back to.
    var showsErrorPage: Bool { url != nil && url == errorShownFor }

    private func recordHistory(_ url: URL, title: String?) {
        // Zigzag's own pages (History, Settings) aren't visits, and neither is a page that failed to load.
        guard !isPrivate, url != lastRecorded, url != errorShownFor, !HistoryPage.isInternal(url) else { return }
        lastRecorded = url
        profile.history.recordVisit(url: url, title: title)
    }

    // MARK: Observation

    private func observe(_ webView: BrowserWebView) {
        observations = [
            webView.observe(\.title, options: [.new]) { [weak self] wv, _ in
                MainActor.assumeIsolated {
                    guard let self, let title = wv.title, !title.isEmpty else { return }
                    // A PDF that names itself keeps that name over WebKit's (its file name, or nothing).
                    if let viewer = self.pdfViewer, viewer.documentTitle != nil, viewer.url == wv.url { return }
                    self.title = title
                    self.changed.send(.title)
                    // Written once the title settles: a page that counts in its title ("(3) Inbox") isn't a database
                    // write every second.
                    if let url = self.url, !self.isPrivate {
                        self.titleWrite?.cancel()
                        let history = self.profile.history
                        let write = DispatchWorkItem { history.updateTitle(title, for: url) }
                        self.titleWrite = write
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: write)
                    }
                }
            },
            webView.observe(\.url, options: [.new]) { [weak self] wv, _ in
                MainActor.assumeIsolated {
                    // A page sending the tab somewhere: the address stays on the page you see until the new one
                    // arrives, so a navigation that never completes can't show another site's name over this page.
                    // In a tab its opener can script, Zigzag's own load waits too: WebKit names it before it starts.
                    // What you chose for this tab with the developer tools is for a development page: the page the
                    // web view is going to gets it, or goes without, before it starts.
                    if let self, !self.developer.isUnchanged { self.applyDeveloperState() }
                    guard let self, !(self.addressWaitsForCommit && wv.isLoading), !(self.openedByPage && self.ownLoadPending != nil) else { return }
                    self.followAddress(of: wv)
                }
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self] wv, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isLoading = wv.isLoading
                    // Nothing on its way any more (a download, a load that stopped without a word).
                    if !wv.isLoading { self.isLeavingPage = false }
                    self.changed.send(.loading)
                    // Back and Forward can bring a PDF back from memory without a finished load: check here too.
                    if !wv.isLoading { self.checkForPDF(wv) }
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
            // The page's certificate came (or changed): the address says whether it's one let through on the warning.
            webView.observe(\.serverTrust, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.changed.send(.navigation) }
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
            // A page that turns dark after it loads (Gmail): the bar above the page follows its color.
            webView.observe(\.underPageBackgroundColor, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.changed.send(.themeColor) }
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

    /// The page and icon links the tab's icon came from, so the second look at the same page (on commit, then on
    /// finish) doesn't fetch and save it again, which redraws every window's sidebar.
    private var iconSource: (page: URL, links: [[String: String]])?
    /// The site whose page was last committed here, so a private tab keeps its zoom from page to page on it.
    private var zoomHost: String?
    /// The page last committed here: the site the tab's icon belongs to.
    private var committedURL: URL? { didSet { refreshDevelopment() } }

    /// Whether the icon stays as a new page commits: only on the same site (www. or not). The first page committed
    /// in a tab keeps the icon it was restored with.
    nonisolated static func keepsIcon(from previous: URL?, to committed: URL) -> Bool {
        guard let previous else { return true }
        func site(_ url: URL) -> String {
            let host = url.host()?.lowercased() ?? url.scheme ?? ""
            return host.withoutWWW
        }
        return site(previous) == site(committed)
    }
    /// The title waiting to go into History, a moment after the page last changed it.
    private var titleWrite: DispatchWorkItem?

    fileprivate func refreshFavicon() {
        guard let webView, let pageURL = webView.url else { return }
        // Private tabs only use icons already saved from normal browsing; they never fetch or save one.
        if isPrivate || Self.isExtensionPage(pageURL) || HistoryPage.isInternal(pageURL) {
            favicon = FaviconStore.shared.cachedIcon(for: pageURL)
            changed.send(.favicon)
            return
        }
        webView.evaluateJavaScript(PageScripts.iconLinks) { [weak self] result, _ in
            MainActor.assumeIsolated {
                let links = (result as? [[String: String]]) ?? []
                if let self, self.favicon != nil, let source = self.iconSource, source.page == pageURL, source.links == links { return }
                FaviconStore.shared.resolve(pageURL: pageURL, links: links) { image in
                    guard let self, let image, self.url?.host() == pageURL.host() else { return }
                    self.iconSource = (pageURL, links)
                    self.favicon = image
                    self.changed.send(.favicon)
                }
            }
        }
    }
}

// MARK: - WKNavigationDelegate

extension Tab: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        let userInitiated = PopupNotice.isUserInitiated(navigationAction)
        // Zigzag's own load counts for the main frame's next decision only, whatever comes of it (a download, an
        // app's link): never for a later one the page starts.
        let decidesMainFrame = navigationAction.targetFrame?.isMainFrame == true
        let ownSender = decidesMainFrame ? ownLoadPending : nil
        let ownLoad = ownSender != nil
        let ownHistory = decidesMainFrame && ownHistoryTarget != nil && navigationAction.request.url == ownHistoryTarget
        if decidesMainFrame {
            ownLoadPending = nil
            ownHistoryTarget = nil
        }
        if navigationAction.shouldPerformDownload {
            // A download link you click saves. One a script starts on its own saves too (an export that's ready),
            // but not a stream of them: another within half a minute is refused.
            if !userInitiated {
                if let last = lastScriptDownload, Date().timeIntervalSince(last) < 30 {
                    Diagnostics.note("Download refused", site: url?.host(), "A page started another download without a click", isPrivate: isPrivate)
                    return (.cancel, preferences)
                }
                lastScriptDownload = Date()
            }
            return (.download, preferences)
        }
        // A click inside a frame lets that frame hand over a file a moment later (a download page's hidden frame).
        if navigationAction.targetFrame?.isMainFrame == false, userInitiated { frameClickedAt = Date() }

        guard let url = navigationAction.request.url else { return (.cancel, preferences) }
        // JavaScript turned off with the developer tools is off for a development page: decided for the page being
        // gone to, so one anywhere else never loads without its scripts.
        if decidesMainFrame, developerInEffect(at: url).javaScriptOff { preferences.allowsContentJavaScript = false }
        // The page is asked for as the browser it's to be told it's in (the developer tools' User Agent): a request
        // made as another is made again, so no page off the list is asked for as one you chose for your own site.
        if decidesMainFrame {
            let wanted = developerInEffect(at: url).userAgent.string
            let again = Self.asksAgain(sent: webView.customUserAgent, wanted: wanted, isGet: (navigationAction.request.httpMethod ?? "GET") == "GET",
                                       type: navigationAction.navigationType)
            if (webView.customUserAgent ?? "") != (wanted ?? "") { webView.customUserAgent = wanted }
            if again {
                // Once this one is refused, so the new one is its own navigation, decided on its own.
                let request = navigationAction.request
                DispatchQueue.main.async { [weak self, weak webView] in
                    guard let self, let webView, self.webView === webView else { return }
                    if let ownSender { self.load(url, in: webView, by: ownSender) } else { webView.load(request) }
                }
                return (.cancel, preferences)
            }
        }

        // Schemes the web view cannot handle go to the system (mailto:, facetime:, app links). Extension pages stay here.
        // "Visit this site anyway" on the certificate warning: trust it for this session and go. Only a click on the
        // warning this tab is showing, in its own main frame (not a window that opened it), for that same host, with
        // that warning's nonce; any other page or frame asking for it gets nothing.
        if url.scheme == CertificateExceptions.scheme {
            let fromWarning = Self.isClickOnWarning(targetsMainFrame: navigationAction.targetFrame?.isMainFrame == true,
                                                    sourceIsMainFrame: navigationAction.sourceFrame.isMainFrame,
                                                    sameWebView: navigationAction.sourceFrame.webView === webView, userInitiated: userInitiated,
                                                    pageHost: webView.url?.host()?.lowercased(), warnedHost: certificateWarningHost)
            if fromWarning, let nonce = certificateWarningNonce,
               let real = CertificateExceptions.destination(of: url, warnedHost: certificateWarningHost, nonce: nonce), let host = real.host() {
                CertificateExceptions.allow(host, certificate: certificateWarningCertificate, in: webView.configuration.websiteDataStore)
                certificateWarningHost = nil
                certificateWarningNonce = nil
                DispatchQueue.main.async { [weak self] in self?.load(real) }
            }
            return (.cancel, preferences)
        }
        // Zigzag's own pages (Settings, History) open from Zigzag or from one another, never because a website
        // sent the tab there: a page could time it so your next click lands on a switch.
        if url.scheme?.lowercased() == HistoryPage.scheme,
           !Self.mayGoToInternalPage(ownLoad: ownLoad, ownHistory: ownHistory, isBackForward: navigationAction.navigationType == .backForward,
                                     fromInternalPage: navigationAction.sourceFrame.securityOrigin.protocol == HistoryPage.scheme) {
            return (.cancel, preferences)
        }
        if ExternalLinks.isExternal(url) {
            ExternalLinks.open(url, isMainFrame: navigationAction.targetFrame?.isMainFrame ?? true,
                               isClick: PopupNotice.isUserInitiated(navigationAction),
                               linkClick: navigationAction.navigationType == .linkActivated, from: webView,
                               asker: navigationAction.sourceFrame.securityOrigin, byYou: ownSender == .you)
            return (.cancel, preferences)
        }

        // Going between an extension's pages and the web takes a different web view. Only an extension's page may
        // cross: a website sending you into an extension's own pages would get them a web view set up with the
        // extension's powers, so that's refused (Zigzag's own loads, from the address bar or an extension, swap in load).
        if navigationAction.targetFrame?.isMainFrame ?? true, Self.isExtensionPage(url) != showsExtensionPage,
           ["http", "https", "webkit-extension"].contains(url.scheme?.lowercased() ?? "") {
            if showsExtensionPage { DispatchQueue.main.async { [weak self] in self?.load(url) } }
            return (.cancel, preferences)
        }

        let isLinkClick = navigationAction.navigationType == .linkActivated
        // Anything you do yourself ends the pinned page's settling-in.
        if isLinkClick || navigationAction.navigationType == .formSubmitted { landingUntil = nil }
        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        // Only a link to the web opens elsewhere (a tab, a card): one to a file or a script stays the page's to try,
        // where WebKit holds it to what the page may reach.
        if isLinkClick && isMainFrame && Self.route(forPageLink: url, from: self.url) == .load {
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
            // A pinned tab or favorite keeps its site: a link that leaves it opens beside it, in a new tab, so the
            // pinned Gmail is still Gmail when you come back. A site installed as an app sends it to the browser.
            // Signing in still happens right here.
            if bookmarkID != nil || isFavorite || keepsSite, let here = self.url, Self.leavesSite(from: here, to: url) {
                host?.tab(self, openURL: url, disposition: .foregroundTab)
                return (.cancel, preferences)
            }
        }
        if isMainFrame {
            pdfFreshLoad = navigationAction.navigationType != .backForward
            pageIsGet = (navigationAction.request.httpMethod ?? "GET").uppercased() == "GET"
            // The page's ad blocking follows where it's going: allowed sites load without it. Only now, once it's
            // going there: a link opened elsewhere leaves this page's blocking as it was.
            if !showsExtensionPage { ContentBlocker.apply(to: webView, for: url) }
            // Back, Forward and Reload go to pages you've had; anything else the page started waits to show.
            addressWaitsForCommit = openedByPage || (!ownLoad && ![.backForward, .reload].contains(navigationAction.navigationType))
        }
        // The community lists' scriptlets for the document's site, in place before it starts (a frame's follow the
        // page it's in, as the blocklist does).
        if !showsExtensionPage { await ContentBlocker.prepareFilters(in: webView, for: url, mainFrame: isMainFrame) }
        return (.allow, preferences)
    }

    /// Whether a "Visit anyway" link came from the certificate warning itself: a click in the main frame of the web
    /// view showing it, on the host it warned about.
    static func isClickOnWarning(targetsMainFrame: Bool, sourceIsMainFrame: Bool, sameWebView: Bool, userInitiated: Bool,
                                 pageHost: String?, warnedHost: String?) -> Bool {
        targetsMainFrame && sourceIsMainFrame && sameWebView && userInitiated && warnedHost != nil && pageHost == warnedHost
    }

    /// Whether a navigation may land on one of Zigzag's own pages: Zigzag's own load, Back or Forward, or a link
    /// from another of its pages. Back and Forward only when Zigzag started them: a page can call history.back().
    static func mayGoToInternalPage(ownLoad: Bool, ownHistory: Bool, isBackForward: Bool, fromInternalPage: Bool) -> Bool {
        ownLoad || ownHistory || (fromInternalPage && !isBackForward)
    }

    /// The site a URL belongs to, so mail.google.com and accounts.google.com count as one: the last two parts of
    /// the host, or three under a country's own second level (bbc.co.uk).
    nonisolated static func site(of url: URL) -> String? {
        guard let host = url.host()?.lowercased(), !host.isEmpty else { return nil }
        let parts = host.split(separator: ".")
        guard parts.count > 2 else { return host }
        let secondLevel: Set<Substring> = ["co", "com", "org", "net", "ac", "gov", "edu", "ne", "or", "go"]
        let keep = parts.last!.count == 2 && secondLevel.contains(parts[parts.count - 2]) ? 3 : 2
        return parts.suffix(keep).joined(separator: ".")
    }

    /// Whether a link you click from `here` to `url` goes to another site, so a tab that keeps its site (a pinned
    /// page, a favorite, a site installed as an app) hands it on. A page that signs you in stays.
    nonisolated static func leavesSite(from here: URL, to url: URL) -> Bool {
        site(of: here) != site(of: url) && !isSignIn(url)
    }

    /// Pages that sign you in to the site you're on, which have to stay in its tab to work.
    nonisolated static func isSignIn(_ url: URL) -> Bool {
        let host = url.host()?.lowercased() ?? ""
        let path = url.path.lowercased()
        return ["accounts.", "login.", "auth.", "signin.", "sso.", "id.", "appleid."].contains { host.hasPrefix($0) }
            || ["/login", "/signin", "/sign-in", "/oauth", "/sso"].contains { path.hasPrefix($0) }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        let response = navigationResponse.response
        // A site that asks to be reached only securely gets no "Visit anyway" on a certificate warning later.
        StrictTransport.note(response, in: webView.configuration.websiteDataStore)
        // A server error with nothing in it (a proxy on this Mac that couldn't reach the site) would be a blank
        // page: the error page says what happened instead, once this load has stopped.
        if navigationResponse.isForMainFrame, let failure = ErrorPage.emptyServerFailure(response) {
            DispatchQueue.main.async { [weak self, weak webView] in
                guard let self, let webView, self.webView === webView else { return }
                self.handle(failure, in: webView)
            }
            return .cancel
        }
        let mime = (response.mimeType ?? "").lowercased()
        // A PDF on its way: Zigzag's viewer covers the page as soon as it commits, before WebKit's own shows.
        if navigationResponse.isForMainFrame { pdfResponseURL = mime == "application/pdf" ? response.url : nil }
        let disposition = ((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition") ?? "").lowercased()
        // A web page is shown, always. WebKit can briefly say it can't show HTML (a response handed over by a
        // service worker, as YouTube's first load does), and a page saved as "youtube.com.html" is never right.
        let isWebPage = mime.isEmpty || ["text/html", "application/xhtml+xml", "text/plain", "application/json", "text/xml", "application/xml"].contains(mime)
        let isAttachment = disposition.hasPrefix("attachment") && (!isWebPage || disposition.contains("filename"))
        // Files in frames aren't saved behind the person's back: only the page itself, or a frame just clicked.
        let frameMaySave = navigationResponse.isForMainFrame || frameClickedAt.map { Date().timeIntervalSince($0) < 10 } == true
        let policy: WKNavigationResponsePolicy
        if isAttachment {
            policy = frameMaySave ? .download : .cancel
        } else if isWebPage || navigationResponse.canShowMIMEType {
            policy = .allow
        } else {
            policy = frameMaySave ? .download : .cancel
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

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLeavingPage = true
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        isLeavingPage = false
        forgetPageErrors()
        // The new page is here: its address shows.
        addressWaitsForCommit = false
        if webView.url != url { followAddress(of: webView) }
        // Answers to the last page's questions were for that page: this one asks again.
        permissionAnswers.forget()
        // A sign-in menu belongs to the page it opened on.
        Autofill.shared.hide()
        // Its dialogs start over: blocking them was for the page you blocked, not a reload of it.
        PageDialogs.pageLoaded(webView)
        // Back after its page stopped: why, if it's something you'd otherwise wonder about.
        if let stop = stoppedFor {
            stoppedFor = nil
            if let text = stop.reloadedText, webView.window != nil, let controller = host as? BrowserWindowController {
                Toast.show(text, symbol: "memorychip", duration: 5, closes: true, in: controller)
            }
        }
        let fresh = pdfFreshLoad
        pdfFreshLoad = false
        // A new page: a PDF that couldn't open before gets another try, unless it brought the helper down
        // (`SafePDF.broughtDownTheHelper`).
        pdfFailed = []
        checkForPDF(webView, fresh: fresh)
        hasLoadedOnce = true
        // The page's own icon as soon as it's here, not only once it finishes (some sites never quite do).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.refreshFavicon() }
        // A new page under a tab that isn't showing: its picture is of the old one, and can't be retaken until it
        // shows. The card falls back to the site's icon rather than show the wrong page.
        if webView.window == nil, snapshot != nil {
            snapshot = nil
            SnapshotStore.remove(id)
            changed.send(.snapshot)
        }
        if let url = webView.url {
            // A new page from another site never wears the last one's icon, even where the address showed it before
            // it came (Zigzag's own loads): the site's own if it's known, otherwise the globe until the page offers one.
            if !Self.keepsIcon(from: committedURL, to: url) {
                favicon = FaviconStore.shared.cachedIcon(for: url)
                iconSource = nil
                changed.send(.favicon)
            }
            committedURL = url
            // What the developer tools put into a page itself (its outlines) goes into the new one, now that the
            // tab knows whether this is a development page.
            if !developer.isUnchanged { applyDeveloperStateToPage() }
            // A private window's zoom isn't saved for the site, so it lasts while you stay on that site in this tab.
            let host = HistoryStore.normalizedHost(url)
            if !(isPrivate && host == zoomHost) {
                let zoom = ZoomLevels.zoom(for: url)
                if webView.pageZoom != zoom { webView.pageZoom = zoom }
            }
            zoomHost = host
            if isSearchTab, !SearchFolding.isSearchResultsPage(url) { isSearchTab = false }
            errorShownFor = ErrorPage.consume(webView) ? url : nil
            recordHistory(url, title: webView.title)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Back, Forward and reload end here too, even where the address stays the same.
        navigatedSinceSave = true
        // The page is all here now: what the developer tools put into it is too.
        if !developer.isUnchanged { applyDeveloperStateToPage() }
        addressWaitsForCommit = false
        if let until = landingUntil, Date() < until, let url = webView.url { pinnedLanding = url }
        checkForPDF(webView)
        refreshFavicon()
        restorePageState(in: webView)
        // A tab without a picture yet gets one once its page has drawn.
        if snapshot == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self, self.webView === webView, self.snapshot == nil else { return }
                self.captureSnapshot()
            }
        }
        Task { [weak self] in
            let article = await Reader.isArticle(webView)
            // Read ahead only for the page you're looking at: ten links opened in the background shouldn't each be
            // parsed and have their pictures fetched. Reader still opens on any page; it just reads it then.
            if article, webView.window != nil { Reader.prepare(webView); ReaderView.prewarm(for: webView.configuration.websiteDataStore) }
            guard let self, self.webView === webView, article != self.isArticle else { return }
            self.isArticle = article
            self.changed.send(.reader)
        }
        checkLanguage(of: webView)
    }

    /// Reads the page's language. A page that draws its text after it loads (a web app, a feed) has too little to
    /// tell at first: it's read again a moment later, a couple of times (#218).
    private func checkLanguage(of webView: WKWebView, after delay: TimeInterval = 0, retries: Int = 2) {
        languageCheck += 1
        let check = languageCheck
        let url = webView.url
        Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard let self, self.languageCheck == check, self.webView === webView, webView.url == url, !self.isTranslated else { return }
            let seen = await PageTranslator.pageLanguage(of: webView)
            let language = await PageTranslator.foreign(seen)
            guard self.languageCheck == check, self.webView === webView, webView.url == url, !self.isTranslated else { return }
            self.foreignLanguage = language
            self.changed.send(.language)
            if seen == nil, retries > 0 { self.checkLanguage(of: webView, after: 2, retries: retries - 1) }
        }
    }

    /// A failure after the page started showing (a stalled image, a dropped connection near the end) leaves the
    /// page as it is: you may be reading it. Only a page that never arrived gets the error page.
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {}

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        isLeavingPage = false
        // It never came: the address goes back to the page still showing.
        addressWaitsForCommit = false
        if webView.url != url { followAddress(of: webView) }
        handle(error, in: webView)
    }

    private func handle(_ error: Error, in webView: WKWebView) {
        let nsError = error as NSError
        // Cancelled loads, frame-load-interrupted (downloads, policy changes) and media WebKit plays itself (a direct
        // .mp4 or .mp3 link, reported as "plug-in handled load") are not failures.
        if nsError.code == NSURLErrorCancelled || (nsError.domain == "WebKitErrorDomain" && [102, 204].contains(nsError.code)) { return }
        let failingURL = (nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? url
        // "Visit anyway" only with the very certificate it trusts in hand, and never for a site that asked to be
        // reached only securely (HSTS): then the warning says why there's no way past.
        let failingHost = failingURL?.host()?.lowercased()
        let certificate = ErrorPage.offersProceed(nsError) ? CertificateExceptions.certificate(in: nsError) : nil
        let store = webView.configuration.websiteDataStore
        let strict = failingHost.map { StrictTransport.isKnown($0, in: store) } ?? false
        let offers = ErrorPage.offersProceed(nsError) && failingHost != nil && CertificateExceptions.mayOffer(certificate: certificate, strictTransport: strict)
        certificateWarningHost = offers ? failingHost : nil
        certificateWarningCertificate = offers ? certificate : nil
        certificateWarningNonce = offers ? CertificateExceptions.makeNonce() : nil
        let noWayPast: ErrorPage.NoWayPast? = !ErrorPage.offersProceed(nsError) || offers ? nil : strict ? .strictTransport : .noCertificate
        Diagnostics.note("Page didn’t load", site: failingURL?.host(), Diagnostics.describe(nsError), isPrivate: isPrivate)
        ErrorPage.show(error: nsError, url: failingURL, in: webView, proceedNonce: certificateWarningNonce, noWayPast: noWayPast)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        pageStopped(webView, reason: nil)
    }

    /// The same, with WebKit's reason (its private `_WKProcessTerminationReason`); WebKit calls this one instead
    /// when it's here.
    @objc(_webView:webContentProcessDidTerminateWithReason:)
    func webView(_ webView: WKWebView, webContentProcessDidTerminateWithReason reason: Int) {
        pageStopped(webView, reason: reason)
    }

    private func pageStopped(_ webView: WKWebView, reason: Int?) {
        let stop = PageStop(webKitReason: reason, lowOnMemoryAgo: MemoryPressure.shared.warningAgo)
        let site = (url ?? webView.url)?.host()
        stoppedFor = stop
        restoresPageState = pageState?.belongs(to: webView.url ?? url) == true
        // Out of sight, it waits until it's next shown: memory pressure doesn't reload every background tab at once.
        guard webView.window != nil else {
            reloadWhenShown = true
            Diagnostics.note("Page stopped", site: site, "\(stop.detail), reloads when shown", isPrivate: isPrivate)
            return
        }
        let now = Date()
        crashes = crashes.filter { now.timeIntervalSince($0) < 60 } + [now]
        Diagnostics.note("Page stopped", site: site, "\(stop.detail), " + (crashes.count >= 2 ? "twice in a minute" : "reloaded"), isPrivate: isPrivate)
        // Twice in a minute: say so, rather than crash and reload forever.
        if crashes.count >= 2 {
            stoppedFor = nil
            restoresPageState = false
            ErrorPage.show(error: NSError(domain: ErrorPage.crashDomain, code: 1), url: url ?? webView.url, in: webView)
            return
        }
        // Crashed before anything loaded: load its address, since there's nothing to reload.
        if webView.url == nil, let url { loadOwn(url, in: webView) } else { webView.reload() }
    }

    /// Shown again after its page stopped while out of sight.
    func reloadIfItStopped() {
        guard reloadWhenShown, let webView else { return }
        reloadWhenShown = false
        if webView.url == nil, let url { loadOwn(url, in: webView) } else { webView.reload() }
    }

    func webView(_ webView: WKWebView, respondTo challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        await AuthenticationPrompt.respond(to: challenge, window: host?.hostWindow, store: webView.configuration.websiteDataStore, page: webView,
                                           tab: isPrivate ? nil : self)
    }
}

// MARK: - WKUIDelegate

extension Tab: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // Zigzag's own Open in New Tab, New Window or Peek always opens; a page's own request needs a click or your say.
        guard BrowserWebView.pendingDisposition(for: webView) != nil || PopupNotice.allows(navigationAction, from: url, isPrivate: isPrivate) else { return nil }
        // Zigzag's own pages never open as a page's new window: Settings would show over it before anything loaded.
        guard Self.mayOpenInNewWebView(navigationAction.request.url) else {
            _ = BrowserWebView.takePendingDisposition(for: webView)
            return nil
        }
        return host?.tab(self, createWebViewWith: configuration, for: navigationAction, features: windowFeatures)
    }

    func webViewDidClose(_ webView: WKWebView) {
        host?.tabDidRequestClose(self)
    }

    /// Right-click › Download Image or Download Linked File. WebKit hands these to the browser through this
    /// (unpublished but long-standing) delegate method; without it they'd go nowhere.
    @objc(_webView:contextMenuDidCreateDownload:)
    func webView(_ webView: WKWebView, contextMenuDidCreate download: WKDownload) {
        DownloadManager.shared.track(download, window: host?.hostWindow)
    }

    /// A page's own Print button (`window.print()`): WebKit asks the browser to print through this (WKUIDelegatePrivate,
    /// unpublished, as Safari answers it); without it the button does nothing. The print panel comes up as for ⌘P, and
    /// the page waits until it's done, so its own "after print" steps run when they should. An iframe's print()
    /// prints that frame; a background tab's is let be.
    @objc(_webView:printFrame:pdfFirstPageSize:completionHandler:)
    func webView(_ webView: WKWebView, printFrame frame: AnyObject?, pdfFirstPageSize size: CGSize, completionHandler: @escaping () -> Void) {
        PagePrinting.printForPage(webView, frame: frame, in: host?.hostWindow, completion: completionHandler)
    }

    /// The same request from older WebKit, which doesn't wait.
    @objc(_webView:printFrame:)
    func webView(_ webView: WKWebView, printFrame frame: AnyObject?) {
        PagePrinting.printForPage(webView, frame: frame, in: host?.hostWindow, completion: {})
    }

    /// The window the page is told it's in (`window.outerWidth` and the rest): the page's own place on screen
    /// (PageWindowFrame). WKUIDelegatePrivate, unpublished; without it a page sees a window of no size at all.
    @objc(_webView:getWindowFrameWithCompletionHandler:)
    func webView(_ webView: WKWebView, getWindowFrameWithCompletionHandler completion: @escaping (CGRect) -> Void) {
        completion(PageWindowFrame.frame(of: webView, hostWindow: host?.hostWindow))
    }

    /// The key icon macOS 27 shows in sign-in fields (AutofillKeyIcon), clicked. WebKit reports it through this
    /// (WKUIDelegatePrivate, unpublished); without it the click is only a click on the field.
    @objc(_webView:didClickAutoFillButtonWithUserInfo:)
    func webView(_ webView: WKWebView, didClickAutoFillButtonWithUserInfo userInfo: Any?) {
        guard let webView = webView as? BrowserWebView else { return }
        Autofill.shared.keyIconClicked(in: webView)
    }

    /// Reported by our hover script: the link under the pointer, or nil.
    func hoveredLinkChanged(_ url: URL?) {
        host?.tab(self, hoveringLink: url)
    }

    /// The floating video's Return button. WebKit puts the video back only once its page is on screen, and asks the
    /// browser to show it here (WKUIDelegatePrivate, unpublished). Without it, Return from another tab does nothing.
    @objc(_webViewFullscreenMayReturnToInline:)
    func webViewFullscreenMayReturnToInline(_ webView: WKWebView) {
        host?.tabWantsToBeShown(self)
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

    /// WebKit's own question for location (not public API, but how Safari asks): answered with Zigzag's prompt.
    @objc(_webView:requestGeolocationPermissionForOrigin:initiatedByFrame:decisionHandler:)
    private func webView(_ webView: WKWebView, requestGeolocationPermissionFor origin: WKSecurityOrigin, initiatedBy frame: WKFrameInfo,
                 decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void) {
        Task { decisionHandler(await SitePermissions.requestLocation(origin: origin, window: host?.hostWindow, isPrivate: isPrivate, tab: self)) }
    }

    // The completion-handler form: its Swift async name differs between SDKs, and a near miss is never called.
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType, decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void) {
        Task { decisionHandler(await SitePermissions.request(origin: origin, type: type, window: host?.hostWindow, isPrivate: isPrivate, tab: self)) }
    }

    /// Screen sharing (Meet, Zoom, Teams). WebKit asks the browser through this unpublished method; the answer
    /// (`DisplayCaptureChoice`) is 2 for macOS's window picker, 1 for its screen picker, 0 for no. Asked every time.
    @objc(_webView:requestDisplayCapturePermissionForOrigin:initiatedByFrame:withSystemAudio:decisionHandler:)
    func webView(_ webView: WKWebView, requestDisplayCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo,
                 withSystemAudio: Bool, decisionHandler: @escaping (Int) -> Void) {
        Task { @MainActor in
            decisionHandler(await SitePermissions.requestDisplayCapture(origin: origin, window: host?.hostWindow, tab: self).rawValue)
        }
    }
}


// MARK: - PDFs

extension Tab {
    /// Whether the page is a PDF, asked of the document itself so Back, Forward and restored tabs are caught too.
    /// A PDF gets Zigzag's viewer, read in the sandboxed PDF helper; anything else drops it. `fresh`: a new load of
    /// the page (Reload, or going to the same address again), which fetches the PDF again even if it's showing.
    func checkForPDF(_ webView: WKWebView, fresh: Bool = false) {
        guard let url = webView.url, !url.absoluteString.hasPrefix("blob:"), url.scheme != "data" else {
            showsPDF = false
            (webView as? BrowserWebView)?.isPDF = false
            setPDFViewer(nil)
            return
        }
        // The response said PDF: the viewer goes up now, while WebKit still loads it (the page can't be asked till then).
        if pdfResponseURL == url { showPDF(url, in: webView, userAgent: nil, fresh: fresh) }
        webView.evaluateJavaScript("[document.contentType, navigator.userAgent]") { [weak self, weak webView] result, _ in
            MainActor.assumeIsolated {
                guard let self, let webView, webView === self.webView, webView.url == url else { return }
                let values = result as? [String]
                // While a PDF still loads, WebKit's page may not say so yet: the response already did.
                guard values?.first == "application/pdf" || self.pdfResponseURL == url else {
                    self.showsPDF = false
                    (webView as? BrowserWebView)?.isPDF = false
                    if self.pdfViewer != nil { self.setPDFViewer(nil) }
                    return
                }
                self.showPDF(url, in: webView, userAgent: values?.count == 2 ? values?[1] : nil, fresh: fresh && self.pdfResponseURL != url)
            }
        }
    }

    /// The page at `url` is a PDF: Zigzag's viewer over it, unless it's showing already (and this isn't a new load).
    private func showPDF(_ url: URL, in webView: WKWebView, userAgent: String?, fresh: Bool) {
        self.showsPDF = true
        (webView as? BrowserWebView)?.isPDF = true
        let showing = self.pdfViewer?.url == url
        // A PDF has no page title, so the last page's would linger: it's named by its file until it says more.
        if !showing {
            let file = url.lastPathComponent
            self.title = file.isEmpty || file == "/" ? (url.host() ?? "") : (file.removingPercentEncoding ?? file)
            self.changed.send(.title)
        }
        // In peek, a form's reply, or one ours couldn't open (on this page, or one that brought the helper down this
        // session, which a reload would only bring down again): WebKit's own viewer shows it.
        guard !self.isPeek, self.pageIsGet, !self.pdfFailed.contains(url), !SafePDF.broughtDownTheHelper(url) else {
            if self.pdfViewer != nil { self.setPDFViewer(nil) }
            return
        }
        guard fresh || !showing else { return }
        // A quiet blank over WebKit's own viewer at once, so it never shows before ours.
        let viewer = PDFViewerView(url: url, isPrivate: self.isPrivate, profile: self.profile.id)
        viewer.onOpenLink = { [weak self] link in self?.load(link, by: .page) }
        viewer.onExternalLink = { [weak webView] link in
            if let webView { ExternalLinks.open(link, isMainFrame: true, isClick: true, from: webView, fromPDF: true) }
        }
        viewer.onSwipe = { [weak webView] event, room in (webView as? BrowserWebView)?.handleSwipe(event, room: room) ?? false }
        // The helper failed on it later (crashed on it, or took too long): WebKit's viewer underneath shows it.
        viewer.onFail = { [weak self, weak viewer] in
            guard let self, let viewer, self.pdfViewer === viewer else { return }
            self.pdfFailed.insert(url)
            self.setPDFViewer(nil)
        }
        self.setPDFViewer(viewer)
        self.pdfTask = Task { @MainActor [weak self, weak webView, weak viewer] in
            guard let webView else { return }
            let data = await PDFViewerView.load(url, from: webView, userAgent: userAgent)
            var opened: (SafePDF, SafePDF.Info)?
            if let data { opened = await PDFViewerView.open(data, from: url) }
            guard !Task.isCancelled, let self, let viewer, self.pdfViewer === viewer, self.webView === webView, webView.url == url else { return }
            // Couldn't fetch or open it: WebKit's viewer underneath shows instead, and stays.
            guard let (document, info) = opened else {
                self.pdfFailed.insert(url)
                self.setPDFViewer(nil)
                return
            }
            viewer.show(document, info: info)
            // The PDF's own title, when it has one, rather than its file name.
            if let name = info.title {
                viewer.documentTitle = name
                self.title = name
                self.changed.send(.title)
            }
        }
    }

    fileprivate func setPDFViewer(_ viewer: PDFViewerView?) {
        guard viewer !== pdfViewer else { return }
        // The old viewer's fetch has nowhere to go.
        pdfTask?.cancel()
        pdfTask = nil
        pdfViewer = viewer
        changed.send(.pdf)
    }
}

// MARK: - Settings

extension Tab {
    /// Settings comes and goes with the tab's address, and its section follows what comes after it.
    fileprivate func refreshSettingsPage() {
        guard webView != nil, SettingsPage.isSettings(url) else {
            if settingsView != nil {
                settingsView = nil
                changed.send(.settings)
                // Leaving Settings for a page: the gear goes with it, and the page's own icon comes in.
                favicon = url.flatMap { FaviconStore.shared.cachedIcon(for: $0) }
                changed.send(.favicon)
                if favicon == nil { refreshFavicon() }
            }
            return
        }
        // Website Data is part of Privacy until there's a second profile.
        let pane = SettingsPage.pane(for: url).shown(manyProfiles: Library.shared.hasManyProfiles)
        if let settingsView {
            if settingsView.pane != pane { settingsView.show(pane) }
            return
        }
        let view = SettingsView(pane: pane)
        if let asked = settingsProfileAsked { view.choose(profile: asked) }
        settingsProfileAsked = nil
        view.onPaneChange = { [weak self] pane in self?.settingsAddressFollows(pane) }
        settingsView = view
        changed.send(.settings)
    }

    /// Opens a section of the Settings this tab shows, or takes the tab there.
    func showSettings(_ pane: SettingsPane) {
        guard let settingsView else { load(SettingsPage.url(for: pane)); return }
        settingsView.show(pane)
        settingsAddressFollows(pane)
    }

    /// Shows a profile's things in the Settings this tab shows, now or once its page is there.
    func showSettings(of profile: UUID) {
        if let settingsView { settingsView.choose(profile: profile) } else { settingsProfileAsked = profile }
    }

    /// The address names the section, without adding a page to Back and Forward, so the tab comes back to it.
    private func settingsAddressFollows(_ pane: SettingsPane) {
        let path = pane == .general ? "/" : "/" + pane.path
        webView?.evaluateJavaScript("history.replaceState(null, '', '\(path)')")
    }
}

extension WKWebView {
    /// Mutes everything the page plays, Web Audio included, as WebKit's own tab muting does, and answers whether the
    /// page's sound is muted now. Nil where WebKit doesn't offer it.
    ///
    /// WebKit keeps one set of muted flags for the page (`_WKMediaMutedState`): its sound, and the camera, microphone
    /// and screen it's capturing. Setting it replaces them all, so only the sound's flag changes here: muting a tab
    /// in a call must never turn its muted microphone back on, nor unmuting it the camera.
    @discardableResult
    func setPageAudioMuted(_ muted: Bool) -> Bool? {
        let set = NSSelectorFromString("_setPageMuted:")
        guard responds(to: set) else { return nil }
        let flags = Self.mutedFlags(pageMutedState ?? 0, audioMuted: muted)
        typealias SetMuted = @convention(c) (AnyObject, Selector, Int) -> Void
        unsafeBitCast(method(for: set), to: SetMuted.self)(self, set, flags)
        return pageMutedState.map(Self.isAudioMuted) ?? muted
    }

    /// WebKit's muted flags for the page, when it says.
    var pageMutedState: Int? {
        let get = NSSelectorFromString("_mediaMutedState")
        guard responds(to: get) else { return nil }
        typealias MutedState = @convention(c) (AnyObject, Selector) -> Int
        return unsafeBitCast(method(for: get), to: MutedState.self)(self, get)
    }

    /// `_WKMediaAudioMuted`: the page's sound. The other flags are its capture devices and screen capture.
    nonisolated static let audioMutedFlag = 1

    nonisolated static func mutedFlags(_ current: Int, audioMuted: Bool) -> Int {
        audioMuted ? current | audioMutedFlag : current & ~audioMutedFlag
    }

    nonisolated static func isAudioMuted(_ flags: Int) -> Bool { flags & audioMutedFlag != 0 }
}
