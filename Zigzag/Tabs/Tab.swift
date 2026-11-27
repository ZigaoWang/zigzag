import AppKit
import WebKit

/// What a tab asks of the window that shows it.
protocol TabHost: AnyObject {
    var hostWindow: NSWindow? { get }
    func tab(_ tab: Tab, openURL url: URL, disposition: OpenDisposition, by sender: Tab.LoadSender)
    /// Offers a shift-click to the host's in-page Mini. False falls back to the standalone Mini.
    @discardableResult
    func tab(_ tab: Tab, openInPageMini url: URL, configuration: WKWebViewConfiguration?, by sender: Tab.LoadSender) -> Bool
    func tab(_ tab: Tab, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, features: WKWindowFeatures) -> WKWebView?
    func tabDidRequestClose(_ tab: Tab)
    /// Back from a tab a link opened, with no page before this one in it.
    func tabWantsToReturnToOpener(_ tab: Tab)
    func tab(_ tab: Tab, hoveringLink url: URL?)
    /// Its floating video's Return button: bring it on screen, so the video can go back into the page.
    func tabWantsToBeShown(_ tab: Tab)
    /// Swiped back or forward in its page: in a split, that page becomes the one you're in, as a click on it would.
    func tabWantsFocus(_ tab: Tab)
    /// True when a route (#286) opened the link in another space. Only browser windows route.
    func tab(_ tab: Tab, routesLink url: URL, arrival: SiteRoutes.Arrival, inBackground: Bool) -> Bool
    /// Its page went in or out of full screen in the window (#462).
    func tab(_ tab: Tab, pageFullScreenChanged on: Bool)
    /// The expand button over a page-filled page: the one explicit hand-off to WebKit's own full screen.
    func tabDidAskToExpandFullScreen(_ tab: Tab)
    /// No one there to answer its pages (AI apps' window): prompts get the quiet answer.
    var isUnattended: Bool { get }
    /// Its window is kept unseen, so its selected tab may sleep.
    var isOutOfSight: Bool { get }
}

extension TabHost {
    func tabWantsFocus(_ tab: Tab) {}
    func tab(_ tab: Tab, openInPageMini url: URL, configuration: WKWebViewConfiguration?, by sender: Tab.LoadSender) -> Bool { false }
    func tab(_ tab: Tab, routesLink url: URL, arrival: SiteRoutes.Arrival, inBackground: Bool) -> Bool { false }
    /// No space of the window's own for the page here (a web app, Zigzag Mini): The Whole Screen is WebKit's, as before.
    func tab(_ tab: Tab, pageFullScreenChanged on: Bool) {
        if on, !tab.profile.isHeadless, PageFullScreen.fills(for: tab.url) == .screen { PageFullScreen.handToWebKit(tab) }
    }
    func tabDidAskToExpandFullScreen(_ tab: Tab) { PageFullScreen.expand(tab) }
    /// Loads an address with no sender: page links and every caller except a rule.
    func tab(_ tab: Tab, openURL url: URL, disposition: OpenDisposition) {
        self.tab(tab, openURL: url, disposition: disposition, by: .page)
    }
    var isUnattended: Bool { false }
    var isOutOfSight: Bool { false }
}

enum OpenDisposition {
    case currentTab
    case foregroundTab
    case backgroundTab
    /// Zigzag Mini over the window (⇧-click, Open Link in Zigzag Mini).
    case mini
    case newWindow
    case privateWindow
}

/// One page in the browser. The tab owns its web view and the holder it sits in; views only borrow the holder to display.
/// A tab can be suspended (web view released, state kept) and restored without the user noticing.
final class Tab: NSObject {
    enum Change {
        case title, url, favicon, loading, progress, navigation, audio, themeColor, activity, snapshot, webView, capture, reader, language, document
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
    /// Its tab group (#209), or nil. Pinned tabs and favorites never have one; TabManager maintains it (see TabGroups).
    var groupID: UUID?

    private(set) var url: URL? {
        didSet {
            refreshDevelopment()
            // A new site may have its own icon (`SiteIcons`).
            if SiteIcons.site(of: url) != SiteIcons.site(of: oldValue) { refreshChosenIcon() }
        }
    }
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
    /// Darkened, it's never light: a light color then is from before Dark Reader reached it (#250). Otherwise the
    /// background under the page, else the theme color.
    static func pageColor(dark: DarkPages.State?, under: NSColor?, theme: NSColor?) -> NSColor? {
        if let dark, dark.darkened, dark.color.map(DarkPages.isDark) != true { return DarkPages.background(black: DarkPages.pureBlack) }
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
    /// The PDF name from `Content-Disposition`, if any.
    private var pdfResponseName: String?
    /// The PDF is over Zigzag's viewer limit: WebKit's viewer shows it and its bytes are never copied or refetched.
    private var pdfResponseTooLarge = false
    /// Settings, over the page while the tab is at zigzag://settings; nil for any other page.
    private(set) var settingsView: SettingsView?
    /// Reader's web view while it covers the page; snapshots use it.
    weak var readerWebView: WKWebView?
    /// The profile Settings was asked to show before this tab had its page: shown once it has.
    private var settingsProfileAsked: UUID?
    private(set) var isPlayingAudio = false
    private(set) var isMuted = false
    private(set) var hasLoadedOnce = false
    private(set) var snapshot: NSImage? {
        didSet {
            snapshotIsDark = snapshot == nil ? nil : webView?.effectiveAppearance.isDark
            // Its card in the tab overview gets the new picture ready ahead of the next open.
            ReadyPictures.renew(snapshot, replacing: oldValue, in: webView?.window)
        }
    }
    /// Whether the app was dark when the snapshot was taken; nil when unknown (read from disk). A mismatch makes it
    /// stale.
    private(set) var snapshotIsDark: Bool?
    var lastActivated: Date
    let createdAt: Date
    /// True for a tab opened by a search from the command bar, until the user leaves the results page.
    var isSearchTab = false
    /// True while the page lives outside a tab list (Zigzag Mini, an installed app). A PDF there is WebKit's; it gets
    /// Zigzag's viewer once it's a tab.
    /// A site installed as an app (`WebAppWindowController`): a link you click to another site goes to the browser.
    var keepsSite = false
    var isOutsideTabList = false {
        didSet { if oldValue, !isOutsideTabList, let webView { checkForPDF(webView) } }
    }
    /// The last ⇧ or ⌥ link click the page kept, for its own navigation right after (#322).
    var followedClick: (url: URL, activation: LinkActivation, at: Date)?
    /// Set for tabs in a private window: their own throwaway storage, and nothing remembered.
    var privateStore: WKWebsiteDataStore? { didSet { if privateStore !== oldValue { refreshChosenIcon() } } }
    var isPrivate: Bool { privateStore != nil }

    /// What makes a fresh start count as used (#433): a page in an everyday browser window, not a private window,
    /// Zigzag Mini, or one of Zigzag's own pages such as Settings.
    static func countsAsBrowsingForSession(isPrivate: Bool, isInBrowserWindow: Bool, url: URL?) -> Bool {
        !isPrivate && isInBrowserWindow && !HistoryPage.isInternal(url)
    }

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
        // Nor does its sessionStorage go along to the other profile's sign-ins.
        pageState = pageState?.withoutSession
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
    /// Its profile's extensions. In a private tab, only those allowed in private windows run (ExtensionHost).
    @available(macOS 15.4, *)
    var extensionHost: ExtensionHost? { profile.extensions }
    /// In a call, in Picture in Picture or the mini player, or used by an AI app: never slept or archived.
    var isInUse: Bool {
        if AgentControl.shared.isUsing(id) { return true }
        guard let webView else { return false }
        return isInMiniPlayer || webView.cameraCaptureState != .none || webView.microphoneCaptureState != .none || webView.isPictureInPictureActive
    }
    /// Its video is playing in the window's mini player, its page with it.
    var isInMiniPlayer = false
    /// Its page fills the page's area with something in full screen (PageFullScreen): The Page with the chrome, or
    /// The Whole Screen with the browser in its own space. Esc in the window leaves it.
    var isInPageFullScreen = false {
        didSet {
            guard isInPageFullScreen != oldValue else { return }
            pageHolder?.onExpand = { [weak self] in
                guard let self else { return }
                self.host?.tabDidAskToExpandFullScreen(self)
            }
            pageHolder?.showsExpand = isInPageFullScreen && !profile.isHeadless
            host?.tab(self, pageFullScreenChanged: isInPageFullScreen)
        }
    }
    /// What you answered the page's questions (camera, location, notifications) while it's open: asked again once
    /// it loads another page or reloads, as a site set to Ask is.
    var permissionAnswers = PagePermissionAnswers()
    /// Per-tab WebRTC choice by origin, for private windows; never saved (`WebRTCProtection`).
    var webRTCHere: [String: Bool] = [:]
    /// Per-tab JavaScript choice by site, for private windows; never saved (`SiteJavaScript`).
    var javaScriptHere: [String: Bool] = [:]
    /// From a site you've let send notifications: kept awake and out of the archive, so they keep coming.
    var notifiesUser: Bool {
        guard !WebNotifications.alwaysDenies(self), let origin = SiteOrigin.of(url) else { return false }
        return SitePermissions.notifications(origin: origin) == true
    }
    /// The tab that opened this one, so closing it can return there.
    weak var opener: Tab? { didSet { opener?.openedHere.add(self) } }
    /// Tabs opened from this one: when it closes, their Back stops offering to return here.
    private let openedHere = NSHashTable<Tab>.weakObjects()
    /// Opened from a link, with nothing earlier in this tab: Back closes it and goes back to the page that opened
    /// it, as Safari and Chrome do.
    var returnsToOpener: Bool {
        guard !canGoBack, !isOutsideTabList, bookmarkID == nil, let opener, !opener.isClosed else { return false }
        // In another window the opener is no longer beside it (shared tabs still count, #162).
        return opener.spaceID == spaceID && (opener.host === host || (store != nil && opener.store === store))
    }
    var canGoBackOrReturn: Bool { canGoBack || returnsToOpener }

    /// The window that made it, or with shared tabs (#162) the one that last showed it. Links and extensions use it.
    weak var host: TabHost?
    /// Its `TabStore`: the window's, or the shared one.
    weak var store: TabStore?
    /// With shared tabs (#162): the window showing its page now or last.
    weak var shownBy: TabManager?

    // MARK: With no one there

    /// No one is there to answer what its page asks (`TabHost.isUnattended`).
    var isUnattended: Bool { host?.isUnattended ?? false }
    /// Where its prompts show; nil with no one there, so each is answered no.
    private var promptWindow: NSWindow? { isUnattended ? nil : host?.hostWindow }

    /// Something a page asked with no one there, answered no for it.
    struct Unanswered: Equatable {
        enum Kind: String { case alert, confirm, prompt, filePicker = "file picker", print, signIn = "sign-in", certificate, app = "open an app", permission }
        let kind: Kind
        /// What the page said, in its own words, or what it asked for.
        var message = ""
        /// The page that asked, which the tab may have left by the time the app is told.
        var page = ""
    }

    /// The latest few things its page asked with no one there, for the AI app using it (`takeUnanswered`).
    private(set) var unanswered: [Unanswered] = []

    /// Kept only where no one was there: anywhere else the person was asked, or will be.
    func noteUnanswered(_ kind: Unanswered.Kind, _ message: String = "") {
        guard isUnattended else { return }
        unanswered.append(Unanswered(kind: kind, message: message, page: url?.absoluteString ?? ""))
        if unanswered.count > 5 { unanswered.removeFirst(unanswered.count - 5) }
    }

    func takeUnanswered() -> [Unanswered] {
        defer { unanswered = [] }
        return unanswered
    }
    /// When its page last stopped unexpectedly, to tell a one-off from a page that keeps stopping.
    private var crashes: [Date] = []
    private var reloadWhenShown = false
    /// Why its page last stopped, until it has loaded again and that's been said.
    private var stoppedFor: PageStop?
    /// Where you were on the page and what you'd typed, read as you left it; it stays while the tab is out of sight.
    /// A sleeping tab's also holds its page's sessionStorage, which is also kept for the next launch (`SavedSessionStorage`).
    private(set) var pageState: PageState? {
        didSet { if oldValue?.session != pageState?.session { SavedSessionStorage.changed() } }
    }
    /// The script putting the woken page's sessionStorage back, until it has run on its origin or a page has loaded.
    private var sessionScript: WKUserScript?
    /// The origin `sessionScript` puts its sessionStorage back on.
    private var sessionScriptOrigin: String?
    /// The page is loading again after it slept or stopped: once it's here, `pageState` puts it back.
    private var restoresPageState = false
    /// Its history was just restored, so WebKit's cached copy of its page is loaded again once it commits.
    private enum RestoredPage { case waiting, reloads }
    private var restoredPage: RestoredPage?
    /// The host whose certificate warning this tab last showed: the only one its "Visit anyway" link may trust.
    private var certificateWarningHost: String?
    /// The certificate that warning was about: the one "Visit anyway" trusts.
    private var certificateWarningCertificate: Data?
    /// The nonce written into that warning's "Visit anyway" link, new for each warning.
    private var certificateWarningNonce: String?
    let changed = Signal<Change>()

    /// The page uses a certificate trusted via "Visit anyway": shown as not secure while in use, even after the
    /// exception expires.
    var usesCertificateException: Bool { CertificateExceptions.isShowingException(in: webView) }

    #if DEBUG
    /// visitanyway: what the warning's "Visit anyway" does, for a test copy whose clicks don't reach the page. Only
    /// while this tab shows a warning that offers it, for that warning's certificate.
    func debugVisitAnyway() {
        guard let webView, let host = certificateWarningHost, certificateWarningNonce != nil, let url = webView.url,
              url.host()?.lowercased() == host,
              CertificateExceptions.allow(host, port: url.port ?? 443, certificate: certificateWarningCertificate,
                                          in: webView.configuration.websiteDataStore) else { return }
        certificateWarningHost = nil
        certificateWarningNonce = nil
        load(url)
    }
    #endif

    /// The page isn't secure: plain http, or a certificate let through on the warning page.
    var isNotSecure: Bool { url?.scheme?.lowercased() == "http" || usesCertificateException }

    private(set) var webView: BrowserWebView?
    /// The handler a page's loopback calls come through, so its sockets can be ended when it leaves.
    private weak var localReceivers: LocalReceiverMessages?
    /// Whether this tab made its web view's configuration, so the loopback door's script and handler are its to change.
    /// A page WebKit opened for another shares its opener's, and is left alone.
    private var ownsPageScripts = false
    /// Where the web view sits, with the Web Inspector when it's docked (`PageHolder`): what shows the tab borrows this,
    /// never the web view alone. Made with the first web view and kept, so the next one appears in its place.
    private(set) var pageHolder: PageHolder?
    /// Back/forward history and scroll position kept while suspended or across launches.
    private var pendingInteractionState: Data?
    private var pendingConfiguration: WKWebViewConfiguration?
    private var observations: [NSKeyValueObservation] = []
    private var observingAudio = false
    /// What WebKit says of its sound, and what the tab shows of it (`isPlayingAudio`).
    private var sound = PageSound()
    private var soundWait: DispatchWorkItem?
    private let videosReported = Coalescer()

    init(id: UUID = UUID(), url: URL?, title: String? = nil, spaceID: UUID, configuration: WKWebViewConfiguration? = nil,
         interactionState: Data? = nil, lastActivated: Date = Date(), createdAt: Date = Date()) {
        self.id = id
        // A web view WebKit made for a page's new window shows no address until its first page arrives: the page
        // that opened it can write into it while a load that never finishes would name another site over it.
        self.url = configuration == nil ? url.map(Self.extensionPageAddress) : nil
        self.title = title ?? (SettingsPage.isSettings(self.url) ? String(localized: "Settings", comment: "The name of the tab showing Zigzag's Settings.") : self.url?.host() ?? String(localized: "New Tab", comment: "The name of a tab with no page yet."))
        self.spaceID = spaceID
        // A page WebKit made for another page's new window is in that page's profile, whatever space it lands in.
        let profile = configuration.flatMap { Profiles.shared.profile(ofStore: $0.websiteDataStore) } ?? Profiles.shared.profile(forSpace: spaceID)
        self.profile = profile
        // AI apps' tabs start muted, each page with them (`ensureWebView`).
        self.isMuted = profile.isHeadless
        self.pendingConfiguration = configuration
        self.pendingInteractionState = interactionState
        self.lastActivated = lastActivated
        self.createdAt = createdAt
        super.init()
        if let url = self.url { favicon = FaviconStore.shared.cachedIcon(for: url) }
        chosenIcon = SiteIcons.icon(for: self.url)
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
    /// Its page came back on its own (`TabSleep.startsQuietly`): it starts no sound until you use it. Ends as that
    /// page arrives, or with a page you load.
    private(set) var startsQuietly = false
    /// Why its page isn't running, for its hover card or a favorite's tooltip; nil while it is. Only a tab put to
    /// sleep tells of memory it freed.
    var notLoadedNote: String? {
        guard !isLoaded else { return nil }
        if let asleepNote { return asleepNote }
        return isRestored
            ? String(localized: "Not loaded since Zigzag reopened. Loads when you click it.", comment: "Under a tab's title in its hover card, or a favorite's tooltip: the tab came back after Zigzag was quit and opened again, and its page loads only once you click it.")
            : String(localized: "Not loaded yet. Loads when you click it.", comment: "Under a tab's title in its hover card, or a favorite's tooltip: the tab's page hasn't loaded yet and loads once you click it.")
    }
    /// Why it was put to sleep this run (not merely not loaded yet after a relaunch), nil awake: the sidebar marks it,
    /// so a tab never seems to have lost its page for no reason.
    private(set) var sleepCause: SleepMemory.Cause?
    var isAsleep: Bool { sleepCause != nil }
    /// About how much memory its page gave back as it slept (`SleepMemory.share`), for the hover card; nil awake.
    private(set) var freedMemory: UInt64?
    /// What the sidebar says of it while it sleeps, nil awake.
    var asleepNote: String? { sleepCause.map { SleepMemory.note($0, freed: freedMemory) } }
    /// A name you gave the tab (double-click to rename); it stays whatever the page calls itself.
    /// While a pinned page is first loading, where it ends up on its own (a site that redirects, like
    /// calendar.google.com) counts as the pinned page, so it's never "moved on" before you've done anything.
    var landingUntil: Date?
    var pinnedLanding: URL?

    /// Pinned while loading: the final URL after redirects (e.g. en.wikipedia.org to its Main Page) also counts as the
    /// saved page, until the load ends plus the usual grace period.
    func settleLandingIfLoading() {
        guard isLoading else { return }
        landingUntil = .distantFuture
    }

    /// Records the URL while a pinned page settles (`landingUntil`).
    private func noteLanding(_ url: URL?) {
        if let until = landingUntil, Date() < until, let url { pinnedLanding = url }
    }
    var customTitle: String? { didSet { if oldValue != customTitle { changed.send(.title); changed.send(.renamed) } } }
    /// An icon you gave the tab (an SF Symbol's name, or an emoji), drawn instead of its site's. The page of a pinned
    /// tab or a favorite shows that one's icon instead (`chosenIcon`).
    var customIcon: String? { didSet { if oldValue != customIcon { refreshChosenIcon() } } }
    /// The chosen icon, or the site's (`SiteIcons`); nil for the favicon. Posts `.favicon` on change.
    private(set) var chosenIcon: String?
    /// The link under the pointer in its page, as the hover script last said: where Pin Link in the page's menu
    /// saves from (#326).
    private(set) var hoveredLink: URL?
    /// The text of the link the pointer is over: what Pin Link names the pinned page after.
    private(set) var hoveredLinkTitle: String?

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
        if settingsChanged, developer.needsReload(from: DeveloperState()) { reloadForDeveloperChoices() }
    }

    /// Reloads for a developer tools change, unless `PageImages.defersReload` reloads once the rule is in.
    private func reloadForDeveloperChoices() {
        if let webView, PageImages.defersReload(of: webView) { return }
        reload()
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
            if isDevelopment, developer.needsReload(from: oldValue) { reloadForDeveloperChoices() }
            changed.send(.developer)
            if developer.imagesOff != oldValue.imagesOff { shareImagesChoice() }
        }
    }

    /// Disable Images is shared with the tabs this one opened or was opened by (`PageImages`); they reload too.
    private func shareImagesChoice() {
        guard let webView else { return }
        for other in PageImages.sharing(with: webView) {
            guard let tab = (other as? BrowserWebView)?.owner, tab !== self, tab.developer.imagesOff != developer.imagesOff else { continue }
            tab.developer.imagesOff = developer.imagesOff
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
        let site = SiteIcons.icon(for: url ?? bookmarkID.flatMap { Library.shared.bookmark($0)?.url }, privateStore: privateStore)
        let icon = Self.chosenIcon(own: customIcon, bookmarkID: bookmarkID, site: site) { Library.shared.bookmark($0) }
        guard icon != chosenIcon else { return }
        chosenIcon = icon
        changed.send(.favicon)
    }

    /// A pinned tab or favorite uses its bookmark's icon; other tabs their own; else the site's icon.
    static func chosenIcon(own: String?, bookmarkID: UUID?, site: String? = nil, bookmark: (UUID) -> Bookmark?) -> String? {
        guard let bookmarkID else { return own ?? site }
        return bookmark(bookmarkID)?.icon ?? site
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
        if ArchivePage.isArchive(url) { return ArchivePage.title }
        if !title.isEmpty { return title }
        // A file on your Mac, or a PDF from the web, is called by its name: it has no title of its own.
        if let url, let name = HistoryStore.fileName(of: url) { return name }
        return url?.host() ?? String(localized: "New Tab", comment: "The name of a tab with no page yet.")
    }
    var isBlank: Bool { url == nil }

    // MARK: Web view lifecycle

    /// Returns the live web view, creating or restoring it if needed.
    @discardableResult
    func ensureWebView() -> BrowserWebView {
        if let webView { return webView }
        let fromWebKit = pendingConfiguration != nil
        let quiet = TabSleep.startsQuietly(restored: isRestored, asleep: sleepCause != nil, openedByPage: fromWebKit)
        sleepCause = nil
        isRestored = false
        freedMemory = nil
        let extensionConfiguration = fromWebKit ? nil : Self.extensionConfiguration(for: url, in: profile)
        let configuration = pendingConfiguration ?? extensionConfiguration ?? WebKitSetup.makeConfiguration(for: profile)
        pendingConfiguration = nil
        // Otherwise a page's new window shares its opener's preferences (WebRTC, styles).
        if fromWebKit { WebKitSetup.separatePreferences(of: configuration) }
        PageLocation.attach(to: configuration)
        if extensionConfiguration != nil {
            configuration.applicationNameForUserAgent = WebKitSetup.applicationNameForUserAgent
            WebKitSetup.turnOffBackspaceNavigation(configuration.preferences)
            FeatureFlags.applyOwn(to: configuration.preferences)
        } else if !fromWebKit {
            WebKitSetup.configure(configuration, for: profile)
            WebNotifications.attach(to: configuration, alwaysDenies: WebNotifications.alwaysDenies(self))
            Passkeys.attach(to: configuration, isPrivate: privateStore != nil, profile: profile)
            HistoryPage.attach(to: configuration)
            WebRTCProtection.attach(to: configuration)
            // The data store is what makes the page private to WebKit: only extensions allowed in private windows reach it.
            if let privateStore { configuration.websiteDataStore = privateStore }
        }
        // Extensions' user scripts (BridgeUserScripts), in a page WebKit opened for another too. Extensions' own
        // pages run none, and private pages only allowed extensions'.
        if #available(macOS 15.4, *), extensionConfiguration == nil,
           configuration.webExtensionController === profile.extensions.controller {
            profile.extensions.bridge.userScripts.attach(configuration.userContentController, isPrivate: privateStore != nil)
            // After the private store above: a private page gets OldTwitter's challenge call only when it may run there.
            profile.extensions.attachOldTwitterSolver(to: configuration, isPrivate: privateStore != nil)
        }
        // A page's own scripts may ask Zigzag to make a loopback call, when Settings and the site's switch both say
        // yes. An extension's own page has its bridge instead, and a private tab keeps WebKit's own networking.
        // The script goes only into an allowed page, so every other page keeps WebKit's own networking.
        ownsPageScripts = !fromWebKit
        if extensionConfiguration == nil {
            localReceivers = fromWebKit ? nil
                : LocalReceiverShim.attach(to: configuration, tab: self, origin: url.flatMap(SiteOrigin.of),
                                           isPrivate: isPrivate)
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
        webView.bouncesSidewaysOnlyWhenWide()
        webView.allowsMagnification = true
        webView.isInspectable = true
        Self.stopsAutomaticInsets(webView)
        if !watchesCover { Self.setWatchesCover(false, of: webView) }
        #if DEBUG
        if DebugBridge.mutesEverything { isMuted = webView.setPageAudioMuted(true) ?? true }
        #endif
        self.webView = webView
        WebRTCProtection.apply(to: webView, for: url, in: self)
        if let pageHolder { pageHolder.hold(webView) } else { pageHolder = PageHolder(holding: webView) }
        observe(webView)
        DarkPages.attach(to: webView)
        PageFullScreen.attach(to: webView)
        PageImages.join(webView)
        // A page opened by another inherits its Disable Images (`shareImagesChoice`).
        if fromWebKit, !developer.imagesOff,
           PageImages.sharing(with: webView).contains(where: { ($0 as? BrowserWebView)?.owner?.developer.imagesOff == true }) {
            developer.imagesOff = true
        }
        // What you chose for this tab with the developer tools comes with a new web view, before its first page is
        // asked for: it's asked for as the browser chosen, and starts with the look chosen.
        if !developer.isUnchanged { applyDeveloperState() } else { applyUserAgent() }

        if Self.isExtensionPage(url), let url {
            // Extension pages always load fresh: their saved history state can come back as a blank page, and one
            // from an extension that's gone gets explained rather than restored.
            pendingInteractionState = nil
            loadOwn(url, in: webView)
        } else if let state = pendingInteractionState {
            restoredPage = .waiting
            putSessionBack(in: webView)
            restoreState(state, in: webView)
            pendingInteractionState = nil
            restoresPageState = pageState?.belongs(to: webView.url ?? url) == true
            // Interaction state restores history but may not start a load on its own.
            if webView.url == nil, let url { loadOwn(url, in: webView) }
        } else if let url, !fromWebKit {
            putSessionBack(in: webView)
            loadFirst(url, in: webView)
        }
        startsQuietly = quiet
        // A new web view starts with sound and playing; carry over what you'd set on the old one.
        if isMuted { setMuted(true) }
        // A development tab's pages are listened to for the count of their errors.
        if isDevelopment { PageErrors.counts(in: webView, true) }
        isPlaybackPaused = false
        refreshSettingsPage()
        changed.send(.webView)
        return webView
    }

    /// What keeps its page awake when you'd put it to sleep (Suspend Page), as it keeps it from sleeping on its own.
    enum StaysAwake: Equatable {
        case sound, call, miniPlayer, pictureInPicture, typedText

        /// Said in the toast when it stays awake.
        var note: String {
            switch self {
            case .sound: String(localized: "Not put to sleep while it plays sound", comment: "Toast after Suspend Page in a tab's menu: the page stays awake because it's playing sound.")
            case .call: String(localized: "Not put to sleep while it uses the camera or microphone", comment: "Toast after Suspend Page in a tab's menu: the page stays awake because it's in a call.")
            case .miniPlayer: String(localized: "Not put to sleep while it plays in the mini player", comment: "Toast after Suspend Page in a tab's menu: the page stays awake because its video plays in the window's mini player.")
            case .pictureInPicture: String(localized: "Not put to sleep while its video is in Picture in Picture", comment: "Toast after Suspend Page in a tab's menu: the page stays awake because its video floats in Picture in Picture.")
            case .typedText: String(localized: "Not put to sleep while it has text you typed", comment: "Toast after Suspend Page in a tab's menu: the page stays awake so what you typed into it isn't lost.")
            }
        }
    }

    /// Why it can't be put to sleep now, nil when it can. Text you typed is known only once the page is asked.
    var staysAwake: StaysAwake? {
        guard let webView else { return nil }
        if isInMiniPlayer { return .miniPlayer }
        if webView.cameraCaptureState != .none || webView.microphoneCaptureState != .none { return .call }
        if webView.isPictureInPictureActive { return .pictureInPicture }
        if isPlayingAudio { return .sound }
        return nil
    }

    /// Releases the web view but keeps everything needed to bring it back. Not while something you typed is in it.
    /// `because`: why, for Help › Report a Problem. `chosen`: you asked (Suspend Page): a page still loading sleeps
    /// too, and `refused` hears what kept it awake.
    func suspend(because reason: String? = nil, chosen: Bool = false, refused: ((StaysAwake) -> Void)? = nil) {
        guard let webView else { return }
        if chosen, let why = staysAwake { refused?(why); return }
        guard !isPlayingAudio, !isInMiniPlayer else { return }
        sleepTicket += 1
        let ticket = sleepTicket
        readPageState(includingSession: true) { [weak self] state in
            self?.sleep(webView, ticket: ticket, state: state, because: reason, chosen: chosen, refused: refused)
        }
        // A page stuck in a loop (what EnergyWatch sleeps) never answers: what was read as you left it decides.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            MainActor.assumeIsolated { self?.sleep(webView, ticket: ticket, state: self?.pageState, because: reason, chosen: chosen, refused: refused) }
        }
    }

    /// The asking for `suspend` still waiting, so whichever of the page's answer and the wait for it comes first decides.
    private var sleepTicket = 0

    /// Whether the page holds text you typed, asked as `suspend` asks: a page that doesn't answer in two seconds goes
    /// by what was read as you left it.
    func checkTypedText(_ completion: @escaping (Bool) -> Void) {
        let answer = Once { (state: PageState?) in completion(state?.hasTypedText == true) }
        readPageState { answer.call($0) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            MainActor.assumeIsolated { answer.call(self?.pageState) }
        }
    }

    /// Runs its closure the first time it's called only.
    private final class Once {
        private var body: ((PageState?) -> Void)?
        init(_ body: @escaping (PageState?) -> Void) { self.body = body }
        func call(_ state: PageState?) {
            let run = body
            body = nil
            run?(state)
        }
    }

    private func sleep(_ webView: BrowserWebView, ticket: Int, state: PageState?, because reason: String?, chosen: Bool,
                       refused: ((StaysAwake) -> Void)?) {
        guard sleepTicket == ticket, self.webView === webView else { return }
        sleepTicket += 1
        guard state?.hasTypedText != true else { refused?(.typedText); return }
        // Let a loading page finish (a redirect after wake, #305); retry next time. Not one stuck in a loop.
        guard !webView.isLoading || chosen || reason == EnergyWatch.sleepReason else { return }
        // Shown again while the page was asked: it stays.
        if chosen, !TabManager.mayStillSleep(self) { return }
        captureSnapshot { [weak self] in
            guard let self, self.webView === webView else { return }
            self.pendingInteractionState = webView.interactionState as? Data
            if let state, state.session != nil { self.pageState = state }
            let freed = chosen ? nil : self.memoryInUse(by: webView)
            self.tearDown(webView, keepingSettings: self.url.map(SettingsPage.isSettings) ?? false)
            self.freedMemory = freed
            self.sleepCause = chosen ? .chosen : reason == EnergyWatch.sleepReason ? .energy : .memory
            self.changed.send(.webView)
            if let reason { Diagnostics.note("Tab put to sleep", site: self.url?.host(), reason, isPrivate: self.isPrivate) }
        }
    }

    /// Its share of its page process's memory, as it goes to sleep: the process's footprint over the tabs awake in it.
    private func memoryInUse(by webView: BrowserWebView) -> UInt64? {
        guard let pid = EnergyWatch.processID(of: webView), pid > 0 else { return nil }
        let sharing = WindowManager.shared.everyOpenTab.filter { tab in
            tab.webView.flatMap(EnergyWatch.processID) == pid
        }.count
        return SleepMemory.share(footprint: ProcessMemory.footprint(pid), tabsSharing: sharing)
    }

    /// Reads where you are on the page and what you've typed (`pageState`), as you leave it and before it sleeps.
    /// `includingSession`: its sessionStorage too, for a tab going to sleep.
    func readPageState(includingSession: Bool = false, _ completion: ((PageState?) -> Void)? = nil) {
        guard let webView, hasLoadedOnce, !Self.isExtensionPage(url), pdfViewer == nil, settingsView == nil else { completion?(pageState); return }
        webView.evaluateJavaScript(includingSession ? PageState.sleepReader : PageState.reader, in: nil, in: .defaultClient) { [weak self, weak webView] result in
            guard let self, let webView, self.webView === webView else { completion?(nil); return }
            // A page that won't say (still loading, or its process gone) keeps what was read before.
            // The sessionStorage goes only to the caller: a tab that then stays awake keeps none of it.
            if case .success(let value) = result, let state = PageState(value, url: webView.url) {
                self.pageState = state.withoutSession
                completion?(state)
                return
            }
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

    /// The sessionStorage its page kept, asleep or as Zigzag last quit, goes back as that page loads (`sessionRestorer`).
    private func putSessionBack(in webView: WKWebView) {
        if let session = pageState?.session, pageState?.belongs(to: url) == true,
           let script = PageState.sessionRestorer(session) {
            let controller = webView.configuration.userContentController
            controller.add(SessionRestored.shared, contentWorld: .defaultClient, name: PageState.sessionMessage)
            controller.addUserScript(script)
            sessionScript = script
            sessionScriptOrigin = session.origin
        }
        pageState = pageState?.withoutSession
    }

    /// Made from the last session: the sessionStorage its page had as Zigzag quit, for its first load to put back.
    func takeSavedSession(_ session: PageState.Session, from page: URL) {
        guard !isPrivate, webView == nil, pageState == nil, PageState(url: page, scroll: .zero).belongs(to: url) else { return }
        pageState = PageState(url: page, scroll: .zero, session: session)
    }

    /// Takes the woken page's sessionStorage script out: it has run, a page has loaded, or the tab moved on.
    private func dropSessionScript(from webView: WKWebView) {
        guard let script = sessionScript else { return }
        sessionScript = nil
        sessionScriptOrigin = nil
        let controller = webView.configuration.userContentController
        OwnScripts.remove(from: controller) { $0 === script }
        controller.removeScriptMessageHandler(forName: PageState.sessionMessage, contentWorld: .defaultClient)
    }

    /// The woken page has its sessionStorage back (`SessionRestored`).
    func sessionRestored() {
        if let webView { dropSessionScript(from: webView) }
    }

    /// A site's data was cleared in `store` (`site` nil: every site's, but the `kept` sites'): sleeping tabs there
    /// forget the sessionStorage they hold for it, so waking doesn't sign you back in.
    static func forgetSessions(in store: WKWebsiteDataStore, site: String? = nil, keeping kept: Set<String> = []) {
        for tab in WindowManager.shared.openTabs { tab.forgetSession(in: store, site: site, keeping: kept) }
        // Gone from the file for the next launch at once.
        SavedSessionStorage.saveNow()
    }

    /// `forgetSessions` for this tab.
    /// Sites are compared as WebKit keeps their data, by registrable domain: clearing app.example.com's clears
    /// accounts.example.com's too.
    func forgetSession(in store: WKWebsiteDataStore, site: String? = nil, keeping kept: Set<String> = []) {
        guard (privateStore ?? profile.storeIfMade) === store,
              let origin = pageState?.session?.origin ?? sessionScriptOrigin else { return }
        let domain = URL(string: origin)?.host().map(SiteDataListing.site(of:))
        if let site {
            guard let domain, domain == SiteDataListing.site(of: site) else { return }
        } else if let domain, kept.contains(where: { SiteDataListing.site(of: $0) == domain }) {
            return
        }
        pageState = pageState?.withoutSession
        // Woken, with the script still waiting to run: it goes too.
        if let webView { dropSessionScript(from: webView) }
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

    /// Freed without closing, it still lets go of its page on the main run loop.
    isolated deinit {
        if let webView { PageRetirement.release(webView) }
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
        // Its holder leaves whatever was showing it (the page card, Zigzag Mini, a card it stayed in during a video's full
        // screen), as its page does.
        pageHolder?.removeFromSuperview()
        if !keepingSnapshot {
            SnapshotStore.remove(id)
            // Undo steps can hold a closed tab for a while; its picture (megabytes, on a Retina screen) needn't.
            snapshot = nil
        }
    }

    /// `keepingSettings`: the page may come back as it was (a sleep), so the Settings view stays for it: building one
    /// again costs the whole first-open time (#357).
    private func tearDown(_ webView: BrowserWebView, keepingSettings: Bool = false) {
        loadTimings.forget()
        dropSessionScript(from: webView)
        Autofill.shared.forget(webView)
        // Tabs that shared the rule keep their images.
        PageImages.set(false, in: webView)
        setPDFViewer(nil)
        if settingsView != nil, !keepingSettings {
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
        videosToken = nil
        videosReported.cancel()
        sound = PageSound()
        soundWait?.cancel()
        soundWait = nil
        coverWait?.cancel()
        coverWait = nil
        ignoresCover = false
        soundStopped = nil
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.owner = nil
        webView.removeFromSuperview()
        self.webView = nil
        PageRetirement.retire(webView)
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
    /// `sameDocument`: the page moved to another of its own routes (pushState); it stays as it's shown.
    private func leavePage(for url: URL, sameDocument: Bool = false) {
        guard url != self.url, !(sameDocument && isTranslated), foreignLanguage != nil || isTranslated else { return }
        foreignLanguage = nil
        isTranslated = false
        changed.send(.language)
    }

    /// `httpFallback`: `url` is https chosen for a scheme-less address; retry once over http if unreachable
    /// (`CommandRanker.Destination`).
    func load(_ url: URL, by sender: LoadSender = .zigzag, httpFallback: Bool = false) {
        let url = Self.extensionPageAddress(url)
        if let webView { dropSessionScript(from: webView) }
        leavePage(for: url)
        // Extension pages and websites need differently set up web views; crossing over swaps it.
        if let webView, Self.isExtensionPage(url) != showsExtensionPage {
            self.url = url
            changed.send(.url)
            tearDown(webView)
            // The new web view loads it first, with this sender.
            firstLoad = FirstLoad(sender: sender, httpFallback: httpFallback)
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
        load(url, in: webView, by: sender, httpFallback: httpFallback)
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
        /// A download rule opening its action's address. Rules never catch this load, or it would loop.
        case rule
    }

    /// Where a page may navigate a tab on its own: only the web. App links go to ExternalLinks (which asks); local
    /// files, javascript:, extension and Zigzag pages are refused, except a local page linking to a file beside it.
    /// data: too: WebKit blocks top-level data: navigation and loading it ourselves (⌘-click, Zigzag Mini) would bypass that.
    enum PageLinkRoute: Equatable { case load, app, refuse }

    static func route(forPageLink url: URL, from page: URL?) -> PageLinkRoute {
        let scheme = url.scheme?.lowercased() ?? ""
        if ["http", "https", "about", "blob"].contains(scheme) { return .load }
        if scheme == "file" { return page?.isFileURL == true ? .load : .refuse }
        if scheme.isEmpty || ["javascript", "data", "webkit-extension", "chrome-extension", HistoryPage.scheme].contains(scheme) { return .refuse }
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
    /// A click on AMO's file link, from the click until its response.
    private var addonsClick: ExtensionStore.AddonsClick?
    /// That file, checked against AMO's API, until it becomes a download.
    private var addonsInstall: (click: ExtensionStore.AddonsClick, file: ExtensionStore.PublishedAddonsFile)?
    /// Its web view was made by WebKit for a page's new window, so that page (its opener) can script it: every
    /// address it goes to waits until it commits, Zigzag's own loads too.
    private var openedByPage = false
    /// Zigzag's own pending load (address bar, external link), so its address shows at once. `.you` for typed or chosen
    /// addresses, so app links open without asking. Never `.page`. Only the main-frame decision for this URL counts.
    private var ownLoadPending: OwnLoad?
    /// True while the page was opened by a download rule, so the rule can't take that navigation or its download.
    /// Cleared on commit, failure or download.
    private var openedByRule = false
    /// The last address a download rule opened. Outlives `openedByRule`, which a failed replaced navigation can clear
    /// early.
    private var ruleOpenedURL: URL?
    /// The address whose handoff question was last declined, so its response and download don't ask again.
    private var ruleDeclinedURL: URL?
    /// The handoff question was declined; the download manager must not ask again for WebKit's download.
    private var declinedRuleDownload = false
    struct OwnLoad: Equatable {
        let sender: LoadSender
        let url: URL
    }
    /// How the tab's initial address loads: the sender (a page's new-tab link is the page's) and whether http fallback
    /// applies.
    var firstLoad = FirstLoad()
    struct FirstLoad: Equatable {
        var sender: LoadSender = .zigzag
        /// An address given without a scheme (`CommandRanker.Destination`).
        var httpFallback = false
    }
    /// One-time http retry for a scheme-less address loaded over https (`CommandRanker.Destination`), as other browsers
    /// do. Ends on another load, a main-frame decision for another URL, or a commit.
    private var pendingHTTPFallback: HTTPFallback?
    struct HTTPFallback: Equatable {
        /// The address tried first.
        let secure: URL
        /// The same address over http.
        let plain: URL
        /// The sender, reused for the http load.
        let sender: LoadSender
    }
    /// Where Zigzag itself is taking this tab back or forward (its buttons, a swipe, the keyboard, restored history):
    /// the only Back or Forward that may land on one of Zigzag's own pages. A page's history.back() may not.
    private var ownHistoryTarget: URL?
    /// Download policy for its pages (same as pop-up windows').
    private let downloads = DownloadPolicy()
    /// When each step of its loads came, for Report a Problem when one stalls (#548).
    let loadTimings = LoadTimings()

    static func isExtensionPage(_ url: URL?) -> Bool { url?.scheme == "webkit-extension" }

    /// Chrome's address for an extension's page, chrome-extension://<id>/<path>, as Zigzag's own: each extension's
    /// pages are at webkit-extension://<id>/ (ExtensionHost). Any other address comes back as it was.
    nonisolated static func extensionPageAddress(_ url: URL) -> URL {
        guard url.scheme?.lowercased() == "chrome-extension", var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let id = parts.host?.lowercased(), !id.isEmpty else { return url }
        parts.scheme = "webkit-extension"
        parts.host = id
        parts.user = nil
        parts.password = nil
        parts.port = nil
        if parts.percentEncodedPath.isEmpty { parts.percentEncodedPath = "/" }
        return parts.url ?? url
    }

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

    /// `httpFallback`: retry once over http if https is unreachable. Without it, a pending fallback holds only for the
    /// same address (a reload).
    private func load(_ url: URL, in webView: WKWebView, by sender: LoadSender, httpFallback: Bool = false) {
        startsQuietly = false
        ownLoadPending = sender == .page ? nil : OwnLoad(sender: sender, url: url)
        if httpFallback {
            pendingHTTPFallback = Self.overHTTP(url).map { HTTPFallback(secure: url, plain: $0, sender: sender) }
        } else if let pending = pendingHTTPFallback, !Self.sameAddress(pending.secure, url) {
            pendingHTTPFallback = nil
        }
        Self.load(url, in: webView)
    }

    /// The sender of a main-frame navigation: the pending own load only if it's for the same URL. WebKit may normalize
    /// it (lowercase host, "/" path, no :443, no dot segments).
    static func ownSender(of pending: OwnLoad?, for request: URL?) -> LoadSender? {
        guard let pending, let request else { return nil }
        return sameAddress(pending.url, request) ? pending.sender : nil
    }

    /// The http URL to retry after a failure that looks like a server without https (`ErrorPage.fallsBackToHTTP`), only
    /// at the original address and never for HSTS sites (WebKit would upgrade anyway). Nil shows the error page.
    static func fallbackURL(for pending: HTTPFallback?, after error: NSError, failing: URL?, strictTransport: Bool) -> URL? {
        guard let pending, let failing, failing.scheme?.lowercased() == "https", sameAddress(pending.secure, failing), !strictTransport,
              ErrorPage.fallsBackToHTTP(ErrorPage.kind(of: error, url: failing)) else { return nil }
        return pending.plain
    }

    /// The https URL as http, otherwise unchanged; nil for other schemes.
    static func overHTTP(_ url: URL) -> URL? {
        guard url.scheme?.lowercased() == "https", var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        parts.scheme = "http"
        return parts.url
    }

    nonisolated static func sameAddress(_ a: URL, _ b: URL) -> Bool {
        if a == b || a.absoluteString == b.absoluteString { return true }
        func tidy(_ url: URL) -> String? {
            guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return nil }
            parts.scheme = parts.scheme?.lowercased()
            parts.host = parts.host?.lowercased()
            if let port = parts.port, (parts.scheme == "https" && port == 443) || (parts.scheme == "http" && port == 80) { parts.port = nil }
            if parts.host != nil {
                parts.percentEncodedPath = withoutDotSegments(parts.percentEncodedPath)
                if parts.percentEncodedPath.isEmpty { parts.percentEncodedPath = "/" }
            }
            return parts.string
        }
        guard let left = tidy(a), let right = tidy(b) else { return false }
        return left == right
    }

    /// Removes "." and ".." segments (RFC 3986, 5.2.4).
    nonisolated static func withoutDotSegments(_ path: String) -> String {
        var output: [Substring] = []
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        for (index, segment) in segments.enumerated() {
            let isLast = index == segments.count - 1
            switch segment {
            case ".":
                if isLast { output.append("") }
            case "..":
                if output.count > 1 { output.removeLast() }
                if isLast { output.append("") }
            default:
                output.append(segment)
            }
        }
        let joined = output.joined(separator: "/")
        return path.hasPrefix("/") && !joined.hasPrefix("/") ? "/" + joined : joined
    }

    /// The first load of a tab made with an address, as whoever gave it.
    private func loadFirst(_ url: URL, in webView: WKWebView) {
        let first = firstLoad
        firstLoad = FirstLoad()
        load(url, in: webView, by: first.sender, httpFallback: first.httpFallback)
    }

    /// Local files need read access granted to their folder; everything else is a plain request.
    static func load(_ url: URL, in webView: WKWebView) {
        // WebKit quietly ignores a page from an extension it doesn't have; say what happened instead.
        let profile = Self.profile(of: webView)
        if isExtensionPage(url), extensionConfiguration(for: url, in: profile) == nil {
            // Opened by an extension that's still loading (1Password's welcome page, right after it installs):
            // wait for it, briefly, before saying the page is unavailable. One that isn't installed says so at once.
            if #available(macOS 15.4, *), url.host().map(profile.installs.hasRecord) == true {
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

    /// Read access for a local page: its folder. For files loose in Downloads or the download folder, only the file
    /// (unless a saved page with "_files"). Never the home folder or above.
    static func readAccess(for file: URL, downloadFolders: [URL] = Tab.downloadFolders,
                           home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)) -> URL {
        let folder = file.deletingLastPathComponent()
        let path = folder.resolvingSymlinksInPath().standardizedFileURL.path
        let homePath = home.resolvingSymlinksInPath().standardizedFileURL.path
        if path == "/" || homePath == path || homePath.hasPrefix(path.hasSuffix("/") ? path : path + "/") { return file }
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
        Freezes.mark("address change")
        guard let url = wv.url else { return }
        let siteChanged = FaviconStore.siteKey(for: url) != self.url.flatMap { FaviconStore.siteKey(for: $0) }
        if url != self.url, self.isArticle { self.isArticle = false; self.changed.send(.reader) }
        // Not loading: a route of the same page, which a translated page keeps translating.
        leavePage(for: url, sameDocument: !wv.isLoading)
        let changedPage = url != self.url
        self.url = url
        self.navigatedSinceSave = true
        // Same-document URL changes (YouTube, GitHub, Gmail) go in history but don't count as visits, so a page can't
        // boost its own ranking.
        if changedPage, !wv.isLoading { self.recordHistory(url, title: nil, countsVisit: false) }
        // Its language too, once the new page has drawn: it never finishes loading to be read then (#218).
        if changedPage, !wv.isLoading { self.checkLanguage(of: wv, after: 1.5) }
        // Another site: never the last site's icon. Its own if it's known, otherwise none until the page offers one.
        if siteChanged {
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
        startsQuietly = false
        // A reload isn't asked for again (`asksAgain`), so a user agent chosen since goes on first.
        applyUserAgent()
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
                // This WebKit has no page muting, so each media element is muted instead, in the document-start world
                // where the page can't override it.
                webView.runOwnScript(Self.elementMuting(muted))
                isMuted = muted
            }
        } else {
            isMuted = muted
        }
        changed.send(.audio)
    }

    #if DEBUG
    /// The row's speaker as if the page played sound or were muted, with the page itself left as it is (screenshots).
    func debugShowSound(playing: Bool, muted: Bool) {
        isPlayingAudio = playing
        isMuted = muted
        changed.send(.audio)
    }
    #endif

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
        Freezes.mark("tab picture")
        guard let webView, webView.window != nil, webView.bounds.width > 0, hasLoadedOnce else { completion?(); return }
        // A PDF's picture is of Zigzag's viewer, as you see it (dark pages and all), not WebKit's underneath.
        // Settings likewise: the picture is of what covers the page, not the empty page under it.
        if let image = pdfViewer.flatMap({ $0.window != nil ? $0.snapshot() : nil }) ?? settingsView.flatMap({ $0.window != nil ? $0.snapshot() : nil }) {
            snapshot = image
            // Window appearance, as covering views draw in it.
            snapshotIsDark = webView.window?.effectiveAppearance.isDark
            if keep, !isPrivate { SnapshotStore.save(image, for: id) }
            changed.send(.snapshot)
            completion?()
            return
        }
        // In Reader, snapshot the article.
        let shown = readerWebView.flatMap { $0.window != nil && $0.bounds.width > 0 ? $0 : nil } ?? webView
        let config = WKSnapshotConfiguration()
        config.afterScreenUpdates = false
        config.snapshotWidth = NSNumber(value: Double(min(shown.bounds.width, 1280)))
        shown.takeSnapshot(with: config) { [weak self] image, _ in
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
        // Settings or the PDF viewer over the page: briefly placed in the window so it draws in the window's
        // appearance.
        let cover: NSView? = pdfViewer ?? settingsView
        if let cover, cover.window == nil, host.window != nil, size.width > 0, size.height > 0 {
            let home = cover.superview, frame = cover.frame, resizing = cover.autoresizingMask
            let above = home.flatMap { home in home.subviews.firstIndex(of: cover).map { home.subviews.dropFirst($0 + 1).first } } ?? nil
            cover.autoresizingMask = []
            cover.frame = NSRect(origin: .zero, size: size)
            host.addSubview(cover)
            cover.layoutSubtreeIfNeeded()
            let image = pdfViewer?.snapshot() ?? settingsView?.snapshot()
            cover.removeFromSuperview()
            if let above { home?.addSubview(cover, positioned: .below, relativeTo: above) } else { home?.addSubview(cover) }
            cover.frame = frame
            cover.autoresizingMask = resizing
            if let image {
                snapshot = image
                snapshotIsDark = host.effectiveAppearance.isDark
                if !isPrivate { SnapshotStore.save(image, for: id) }
                changed.send(.snapshot)
            }
            completion()
            return
        }
        guard let webView, let letGo = holdOutOfSight(in: host, size: size) else {
            completion()
            return
        }
        let config = WKSnapshotConfiguration()
        config.afterScreenUpdates = true
        config.snapshotWidth = NSNumber(value: Double(min(size.width, 1280)))
        // A moment in the window first, for it to draw.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self, weak webView] in
            guard let self, let webView, webView.window != nil else { letGo(); completion(); return }
            // Read while still in the window: the page's own appearance (Dark Pages sets one) or the window's.
            let dark = webView.effectiveAppearance.isDark
            webView.takeSnapshot(with: config) { [weak self] image, _ in
                letGo()
                if let self, let image, !TabThumbnailView.isBlank(image) {
                    self.snapshot = image
                    self.snapshotIsDark = dark
                    if !self.isPrivate { SnapshotStore.save(image, for: self.id) }
                    self.changed.send(.snapshot)
                }
                completion()
            }
        }
    }

    /// Holds on its page out of sight, which placement it is, and its holder's old mask.
    private var outOfSightHolds = 0
    private var outOfSightSetting = 0
    private var resizingBeforeHold: NSView.AutoresizingMask = []

    /// Puts its page in `host` to draw unseen; the last release frees it. Nil with no page or one in a window.
    func holdOutOfSight(in host: NSView, size: NSSize) -> (() -> Void)? {
        guard let webView, let holder = pageHolder, webView.superview === holder, hasLoadedOnce,
              host.window != nil, size.width > 0, size.height > 0 else { return nil }
        if holder.superview === host, outOfSightHolds > 0 {
            outOfSightHolds += 1
        } else {
            guard webView.window == nil else { return nil }
            resizingBeforeHold = holder.autoresizingMask
            holder.autoresizingMask = []
            holder.frame = NSRect(origin: .zero, size: size)
            host.addSubview(holder)
            outOfSightHolds = 1
            outOfSightSetting += 1
        }
        let setting = outOfSightSetting
        return { [weak self, weak holder, weak host] in
            guard let self, setting == self.outOfSightSetting else { return }
            self.outOfSightHolds = max(0, self.outOfSightHolds - 1)
            guard self.outOfSightHolds == 0, let holder, let host, holder.superview === host else { return }
            holder.removeFromSuperview()
            holder.autoresizingMask = self.resizingBeforeHold
        }
    }

    /// Whether the overview should picture a page out of sight: it has a live page that's loaded, it isn't on
    /// screen, and it has no picture yet.
    nonisolated static func needsPictureOutOfSight(hasWebView: Bool, onScreen: Bool, loaded: Bool, hasPicture: Bool) -> Bool {
        hasWebView && !onScreen && loaded && !hasPicture
    }

    /// Whether the snapshot was taken in the other appearance. Unknown counts as current.
    nonisolated static func pictureIsStale(takenDark: Bool?, dark: Bool) -> Bool {
        takenDark.map { $0 != dark } ?? false
    }

    /// Compared with the page's appearance (app or Dark Pages), or the window's when Settings or the PDF viewer covers
    /// it.
    func snapshotIsStale(windowDark: Bool) -> Bool {
        let covered = pdfViewer != nil || settingsView != nil
        let dark = covered ? windowDark : webView?.effectiveAppearance.isDark ?? windowDark
        return Self.pictureIsStale(takenDark: snapshotIsDark, dark: dark)
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

    /// `countsVisit`: false for same-document URL changes; kept in history without raising its rank.
    private func recordHistory(_ url: URL, title: String?, countsVisit: Bool = true) {
        // Zigzag's own pages (History, Settings) aren't visits, and neither is a page that failed to load.
        guard !isPrivate, url != lastRecorded, url != errorShownFor, !HistoryPage.isInternal(url) else { return }
        lastRecorded = url
        // PDFs have no title; use the response name (`pdfName`).
        let named = (title ?? "").isEmpty && pdfResponseURL == url ? pdfName(of: url) : title
        profile.history.recordVisit(url: url, title: named, count: Self.visitCount(countsVisit: countsVisit))
    }

    /// 1 for a load, 0 for a same-document change.
    static func visitCount(countsVisit: Bool) -> Int { countsVisit ? 1 : 0 }

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
                    // Load ended: start the usual grace period (`settleLandingIfLoading`).
                    if !wv.isLoading, self.landingUntil == .distantFuture { self.landingUntil = Date().addingTimeInterval(8) }
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
        watchVideos(of: webView)
    }

    override nonisolated func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        guard keyPath == "_isPlayingAudio" else { return }
        let playing = (change?[.newKey] as? Bool) ?? false
        MainActor.assumeIsolated { self.refreshSound(webKit: playing) }
    }

    /// Plays sound while WebKit says so, unless that sound came from a video or audio that has stopped (`PageSound`).
    private func refreshSound(webKit: Bool? = nil) {
        soundWait?.cancel()
        soundWait = nil
        guard let webView else { return }
        let media = PageVideos.shared.playsSound(in: webView)
        let (playing, recheck) = sound.update(webKit: webKit ?? sound.webKit, media: media)
        if let recheck {
            let wait = DispatchWorkItem { [weak self] in self?.refreshSound() }
            soundWait = wait
            DispatchQueue.main.asyncAfter(deadline: .now() + recheck, execute: wait)
        }
        guard playing != isPlayingAudio else { return }
        isPlayingAudio = playing
        refreshCoverWatch()
        changed.send(.audio)
    }

    // MARK: Covered windows

    /// Whether WebKit hides a page whose window is covered or on another desktop. Debug builds never let it, so
    /// scripted screenshots capture pages behind other apps; ZIGZAG_REAL_OCCLUSION=1 keeps it, as release builds have it.
    static let watchesCover: Bool = {
        #if DEBUG
        return ProcessInfo.processInfo.environment["ZIGZAG_REAL_OCCLUSION"] == "1"
        #else
        return true
        #endif
    }()

    /// Never for AI apps' pages, which run as if seen.
    var watchesCover: Bool { Self.watchesCover && !profile.isHeadless }

    static func setWatchesCover(_ on: Bool, of webView: WKWebView) {
        let occlusion = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        guard webView.responds(to: occlusion) else { return }
        typealias SetBool = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(webView.method(for: occlusion), to: SetBool.self)(webView, occlusion, on)
    }

    /// The wait, once the page stops playing, before a covered window hides it again.
    private var coverWait: DispatchWorkItem?
    /// A covered window doesn't hide the page now (`ignoresCover`).
    private var ignoresCover = false
    /// When its sound stopped, while a covered window still doesn't hide it.
    private var soundStopped: Date?
    /// The page's videos and sound: a covered window hides it again while a video plays; its sound may be over.
    private var videosToken: SignalToken?

    /// A page playing sound with no video showing (a music player) stays on screen to WebKit while its window is
    /// covered (an installed app's behind other apps, most often), and for a while after it stops, so a playlist's
    /// next song can load and start (#199). `_isPlayingAudio` leaves out a silent Web Audio graph.
    private func refreshCoverWatch() {
        guard watchesCover, let webView else { return }
        coverWait?.cancel()
        coverWait = nil
        let video = PageVideos.shared.playing(in: webView, any: true) != nil
        if isPlayingAudio, !video { soundStopped = nil } else if ignoresCover, soundStopped == nil { soundStopped = Date() }
        let quiet = soundStopped.map { Date().timeIntervalSince($0) }
        let ignores = MiniPlayerLayout.ignoresCover(playingSound: isPlayingAudio, showingVideo: video, quiet: quiet)
        if ignores != ignoresCover {
            ignoresCover = ignores
            Self.setWatchesCover(!ignores, of: webView)
        }
        guard ignores else { soundStopped = nil; return }
        guard let quiet else { return }
        let wait = DispatchWorkItem { [weak self] in self?.refreshCoverWatch() }
        coverWait = wait
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, MiniPlayerLayout.nextItemWait - quiet), execute: wait)
    }

    private func watchVideos(of webView: BrowserWebView) {
        guard watchesCover else { return }
        videosToken = PageVideos.shared.reported.observe { [weak self, weak webView] page in
            guard let self, let webView, page === webView, self.webView === webView else { return }
            // Many frames reporting at once: looked at once.
            self.videosReported.schedule { [weak self] in
                self?.refreshSound()
                self?.refreshCoverWatch()
            }
        }
    }

    /// The page and icon links the tab's icon came from, so the second look at the same page (on commit, then on
    /// finish) doesn't fetch and save it again, which redraws every window's sidebar.
    private var iconSource: (page: URL, links: [[String: String]])?
    /// The site whose page was last committed here, so a private tab keeps its zoom from page to page on it.
    private var zoomHost: String?
    /// The page last committed here: the site the tab's icon belongs to.
    private var committedURL: URL? { didSet { refreshDevelopment() } }

    /// Tab icon while an error page is shown: a warning, never the previous page's or site's icon.
    static let errorPageIcon = Tokens.Symbol.image("exclamationmark.triangle", size: Tokens.Symbol.row)

    /// Warning for an error page, else the site's cached icon.
    static func immediateIcon(for url: URL, errorPage: Bool) -> NSImage? {
        errorPage ? errorPageIcon : FaviconStore.shared.cachedIcon(for: url)
    }

    /// Whether the icon stays as a new page commits: only on the same site (www. or not, on its own port). The first
    /// page committed in a tab keeps the icon it was restored with.
    nonisolated static func keepsIcon(from previous: URL?, to committed: URL) -> Bool {
        guard let previous else { return true }
        func site(_ url: URL) -> String { FaviconStore.siteKey(for: url) ?? url.scheme ?? "" }
        return site(previous) == site(committed)
    }
    /// The title waiting to go into History, a moment after the page last changed it.
    private var titleWrite: DispatchWorkItem?

    /// The page changed its icon links (a light or dark swap): read them again.
    func pageIconsChanged() { refreshFavicon() }

    fileprivate func refreshFavicon() {
        guard let webView, let pageURL = webView.url else { return }
        // Error pages keep the warning.
        if showsErrorPage {
            favicon = Self.immediateIcon(for: pageURL, errorPage: true)
            changed.send(.favicon)
            return
        }
        // Private tabs only use icons already saved from normal browsing; they never fetch or save one.
        if isPrivate || Self.isExtensionPage(pageURL) || HistoryPage.isInternal(pageURL) {
            favicon = FaviconStore.shared.cachedIcon(for: pageURL)
            changed.send(.favicon)
            return
        }
        webView.runOwnScript(PageScripts.iconLinks) { [weak self] answer in
            MainActor.assumeIsolated {
                let links = ((try? answer.get()) as? [[String: String]]) ?? []
                if let self, self.favicon != nil, let source = self.iconSource, source.page == pageURL, source.links == links { return }
                FaviconStore.shared.resolve(pageURL: pageURL, links: links) { image in
                    guard let self, let image, let shown = self.url,
                          FaviconStore.siteKey(for: shown) == FaviconStore.siteKey(for: pageURL), !self.showsErrorPage else { return }
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
    /// The AMO page being read, when the address is one. Asked for as Firefox so the store's own button offers the
    /// add-on ("Add to Firefox" → hand over the .xpi) instead of a browser download.
    nonisolated static func addonsPage(_ url: URL) -> URL? {
        guard let host = url.host(), ExtensionStore.addonsHost(host),
              url.scheme?.lowercased() == "https", url.port == nil || url.port == 443 else { return nil }
        return url
    }

    /// A checked Add to Firefox click goes straight to the install sheet, unless downloads from AMO are kept blocked.
    nonisolated static func skipsDownloadQuestion(kept: Bool?) -> Bool { kept != false }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        // The last session's session cookies go back in before its first request, and those an ended network process took.
        let dataStore = webView.configuration.websiteDataStore
        NetworkProcessCookies.check(dataStore)
        if SessionCookies.isRestoring(dataStore) { await SessionCookies.ready(dataStore) }
        let userInitiated = PopupNotice.isUserInitiated(navigationAction)
        // The own load ends at the next main-frame decision so it never lingers. Only a decision for its URL counts as
        // own.
        let decidesMainFrame = navigationAction.targetFrame?.isMainFrame == true
        let ownSender = decidesMainFrame ? Self.ownSender(of: ownLoadPending, for: navigationAction.request.url) : nil
        let ownLoad = ownSender != nil
        let ownHistory = decidesMainFrame && ownHistoryTarget != nil && navigationAction.request.url == ownHistoryTarget
        if decidesMainFrame {
            // WebKit brings a restored page back from its cache, however old.
            if restoredPage == .waiting {
                restoredPage = Self.revalidatesRestoredPage(url: navigationAction.request.url, method: navigationAction.request.httpMethod,
                                                            type: navigationAction.navigationType) ? .reloads : nil
            } else {
                restoredPage = nil
            }
            // A click on AMO's file, read from the page it was made on; any navigation to something else ends it.
            if let click = ExtensionStore.AddonsClick(target: navigationAction.request.url, page: webView.url ?? url, userInitiated: userInitiated) {
                addonsClick = click
            } else if addonsClick?.covers(navigationAction.request.url) != true {
                addonsClick = nil
            }
            // Reset per navigation; redirects keep it. A rule's own load can't be taken by a rule, as a page or a
            // download.
            declinedRuleDownload = false
            if ownSender == .rule {
                openedByRule = true
                ruleOpenedURL = navigationAction.request.url
            } else if [.linkActivated, .formSubmitted, .backForward, .reload].contains(navigationAction.navigationType) {
                openedByRule = false
            }
            // A new click re-asks even for a just-declined address.
            if userInitiated, navigationAction.navigationType == .linkActivated { ruleDeclinedURL = nil }
            ownLoadPending = nil
            ownHistoryTarget = nil
            // The http fallback ends when the main frame goes elsewhere.
            if let pending = pendingHTTPFallback, !(navigationAction.request.url.map { Self.sameAddress(pending.secure, $0) } ?? false) {
                pendingHTTPFallback = nil
            }
        }
        if let frame = navigationAction.targetFrame, !frame.isMainFrame {
            downloads.noteFrame(navigatingTo: navigationAction.request.url, from: SiteOrigin.of(frame.securityOrigin))
        }
        // Clicked downloads save. Script-started ones save too, but not a burst (`DownloadPolicy`); a click or key in
        // the page since the last one lets the next through.
        if let policy = downloads.decide(shouldDownload: navigationAction.shouldPerformDownload, clicked: userInitiated || ownLoad,
                                         isMainFrame: navigationAction.targetFrame?.isMainFrame ?? true,
                                         lastInput: DownloadPolicy.lastInput(in: webView)) {
            // A download rule may take it; then WebKit makes no download.
            if policy == .download, let target = navigationAction.request.url,
               await handOffIfWanted(target, request: navigationAction.request, appliesToLinks: false, webView: webView,
                                     wasClicked: userInitiated,
                                     pageOrigin: askingOrigin(navigationAction, webView: webView)) {
                return (.cancel, preferences)
            }
            // No rule: ask once per site whether it may download. Unprompted downloads never ask, but a stored answer
            // applies.
            if policy == .download, let target = navigationAction.request.url,
               await !mayDownload(target, in: webView, retry: navigationAction.request, asking: userInitiated || ownLoad,
                                  frameSites: navigationAction.targetFrame?.isMainFrame == false ? downloads.frameSites(for: target) : []) {
                return (.cancel, preferences)
            }
            if policy == .cancel {
                // Unprompted download. Allow Once re-requests it from the page to provide the gesture; a request that
                // can't be repeated (POST) leaves the notice as is.
                let origin = SiteOrigin.of(webView.url) ?? SiteOrigin.of(navigationAction.request.url)
                // Never asked: Allow Once refetches without storing an answer.
                refusedDownload(in: webView, action: origin.flatMap {
                    askAgain(origin: $0, request: navigationAction.request, in: webView, keepAnswer: false)
                })
            }
            return (policy, preferences)
        }

        guard let url = navigationAction.request.url else { return (.cancel, preferences) }
        // JavaScript per Settings and site choice (`SiteJavaScript`), for the main frame's target; frames follow their
        // page, as WebKit decides per frame. Zigzag's error pages keep their own.
        SiteJavaScript.apply(to: preferences, for: decidesMainFrame ? url : webView.url, here: javaScriptHere,
                             errorPage: decidesMainFrame && ErrorPage.pending.contains(webView))
        // A page that came back on its own plays no sound until you use it (#493); a click into another page may.
        if decidesMainFrame {
            if TabSleep.autoplaysWithoutSound(startsQuietly: startsQuietly, userInitiated: userInitiated) {
                WebKitSetup.autoplayWithoutSound(preferences)
            } else {
                startsQuietly = false
            }
        }
        // JavaScript turned off with the developer tools is off for a development page: decided for the page being
        // gone to, so one anywhere else never loads without its scripts.
        if decidesMainFrame, developerInEffect(at: url).javaScriptOff { preferences.allowsContentJavaScript = false }
        // The page is asked for as the browser it's to be told it's in (the developer tools' User Agent): a request
        // made as another is made again, so no page off the list is asked for as one you chose for your own site.
        if decidesMainFrame {
            // addons.mozilla.org shows Add to Firefox only to Firefox; then a site's kept choice (#392).
            let wanted = userAgent(at: url)
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

        // A link rule may take the click before anything loads (YouTube to mpv, magnet to rTorrent). Redirects,
        // reloads, history and scripted navigation are skipped.
        if userInitiated, navigationAction.navigationType == .linkActivated, navigationAction.targetFrame?.isMainFrame ?? true,
           await handOffIfWanted(url, request: navigationAction.request, appliesToLinks: true, webView: webView,
                                 wasClicked: true,
                                 pageOrigin: askingOrigin(navigationAction, webView: webView)) {
            return (.cancel, preferences)
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
                CertificateExceptions.allow(host, port: real.port ?? 443, certificate: certificateWarningCertificate,
                                            in: webView.configuration.websiteDataStore)
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
        // Chrome's address for an extension's page: opened from Zigzag or that extension's own pages, refused from others.
        if url.scheme?.lowercased() == "chrome-extension" {
            let page = Self.extensionPageAddress(url)
            let source = navigationAction.sourceFrame.securityOrigin
            let ownPage = source.protocol == "webkit-extension" && source.host.lowercased() == page.host()
            if Self.isExtensionPage(page), navigationAction.targetFrame?.isMainFrame ?? true, ownSender != nil || ownPage {
                DispatchQueue.main.async { [weak self] in self?.load(page, by: ownSender ?? .page) }
            } else {
                Diagnostics.note("Refused a page's link", site: webView.url?.host(), "chrome-extension:", isPrivate: isPrivate)
            }
            return (.cancel, preferences)
        }
        if ExternalLinks.isExternal(url) {
            ExternalLinks.open(url, isMainFrame: navigationAction.targetFrame?.isMainFrame ?? true,
                               isClick: PopupNotice.isUserInitiated(navigationAction),
                               linkClick: navigationAction.navigationType == .linkActivated, sourceIsMainFrame: navigationAction.sourceFrame.isMainFrame, from: webView,
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
        let toTheWeb = Self.route(forPageLink: url, from: self.url) == .load
        // A page navigation to the link a ⇧ or ⌥ click was just on is that click's; a real link click clears the mark.
        if isLinkClick { followedClick = nil }
        // A frame's link opens a tab on ⌘ or a middle click, as on the page; every other click stays the frame's.
        if isLinkClick, !isMainFrame, toTheWeb,
           case .newTab(let inFront) = Self.linkActivation(type: navigationAction.navigationType, isMainFrame: false,
                                                           modifiers: navigationAction.modifierFlags, buttonNumber: navigationAction.buttonNumber) {
            if userInitiated, host?.tab(self, routesLink: url, arrival: .linkNewTab, inBackground: !inFront) == true { return (.cancel, preferences) }
            host?.tab(self, openURL: url, disposition: inFront ? .foregroundTab : .backgroundTab)
            return (.cancel, preferences)
        }
        let followed = isMainFrame && toTheWeb && navigationAction.navigationType == .other ? followedActivation(for: url) : nil
        if (isLinkClick || followed != nil) && isMainFrame && toTheWeb {
            let flags = navigationAction.modifierFlags
            let activation = Self.linkActivation(type: navigationAction.navigationType, isMainFrame: isMainFrame,
                                                 modifiers: flags, buttonNumber: navigationAction.buttonNumber,
                                                 followed: followed)
            // Site routes (#286) apply to clicks and new-tab links; not Zigzag Mini (⇧), download (⌥) or page-initiated.
            let opensTab = activation.isNewTab
            if followed == nil, userInitiated, opensTab || flags.isDisjoint(with: [.shift, .option]),
               host?.tab(self, routesLink: url, arrival: opensTab ? .linkNewTab : .linkClick, inBackground: opensTab && !flags.contains(.shift)) == true {
                return (.cancel, preferences)
            }
            switch activation {
            case .newTab(let inFront):
                host?.tab(self, openURL: url, disposition: inFront ? .foregroundTab : .backgroundTab)
                return (.cancel, preferences)
            case .mini:
                if host?.tab(self, openInPageMini: url, configuration: nil, by: .page) == true { return (.cancel, preferences) }
                host?.tab(self, openURL: url, disposition: .mini)
                return (.cancel, preferences)
            case .download:
                return (.download, preferences)
            case .page:
                break
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
            // The site's zapped elements, hidden from document start (`PageBoosts`).
            PageBoosts.prepare(webView, for: showsExtensionPage ? nil : url, privateStore: privateStore,
                               errorPage: ErrorPage.pending.contains(webView))
            // Set WebRTC for the destination before its page is created (`WebRTCProtection`).
            WebRTCProtection.apply(to: webView, for: url, in: self)
            // Only back/forward and own loads show the address before commit. Reloads wait too: a redirect that never
            // commits mustn't show its name.
            addressWaitsForCommit = openedByPage || (!ownLoad && navigationAction.navigationType != .backForward)
        }
        // The community lists' scriptlets for the document's site, in place before it starts (a frame's follow the
        // page it's in, as the blocklist does).
        if !showsExtensionPage { await ContentBlocker.prepareFilters(in: webView, for: url, mainFrame: isMainFrame) }
        // The loopback door belongs to the page that is about to start, not to the tab. Put in or taken out here, it is
        // in place before that page's own code runs; a page without its switch keeps WebKit's own networking.
        if decidesMainFrame {
            localReceivers = LocalReceiverShim.sync(webView, tab: self, origin: navigationAction.request.url.flatMap(SiteOrigin.of),
                                                    isPrivate: isPrivate, owns: ownsPageScripts, current: localReceivers)
        }
        return (.allow, preferences)
    }

    /// Where a main-frame link click opens: ⌘ or middle click a new tab (⇧ in front), ⇧ Zigzag Mini, ⌥ download, else the
    /// page. `followed` is a ⇧ or ⌥ click the page kept and then navigated to itself.
    enum LinkActivation: Equatable {
        case page, mini, download
        case newTab(inFront: Bool)

        var isNewTab: Bool { if case .newTab = self { true } else { false } }
    }

    nonisolated static func linkActivation(type: WKNavigationType, isMainFrame: Bool, modifiers: NSEvent.ModifierFlags,
                                           buttonNumber: Int, followed: LinkActivation? = nil) -> LinkActivation {
        guard isMainFrame else {
            // In a frame, only ⌘ and the middle button: ⇧ and ⌥ stay the frame's.
            let opensTab = type == .linkActivated && (buttonNumber == 4 || modifiers.contains(.command))
            return opensTab ? .newTab(inFront: modifiers.contains(.shift)) : .page
        }
        if type == .linkActivated {
            // ⌘ wins over ⌥, as in Chrome.
            if buttonNumber == 4 /* middle click */ || modifiers.contains(.command) { return .newTab(inFront: modifiers.contains(.shift)) }
            if modifiers.contains(.shift) { return .mini }
            if modifiers.contains(.option) { return .download }
            return .page
        }
        return followed ?? .page
    }

    /// A ⇧-click the page handled itself: no web view comes back for WebKit's configuration to belong to, so the Mini
    /// gets none, matching the off path that opens the standalone Mini.
    @discardableResult
    func openPageHandledMini(_ url: URL) -> Bool {
        host?.tab(self, openInPageMini: url, configuration: nil, by: .page) == true
    }

    /// Where a request for a new window opens. A real link click uses `linkActivation`'s precedence (⌘ wins, ⇧ alone is
    /// Zigzag Mini); a page that handled the click itself (`window.open`, YouTube and parts of Google) is known by the
    /// URL-scoped click record, taken once.
    func newWindowActivation(for url: URL?, type: WKNavigationType, isMainFrame: Bool,
                             modifiers: NSEvent.ModifierFlags, buttonNumber: Int) -> LinkActivation {
        if type == .linkActivated {
            return Self.linkActivation(type: type, isMainFrame: isMainFrame, modifiers: modifiers, buttonNumber: buttonNumber)
        }
        return followedActivation(for: url) ?? .page
    }

    /// How long after a ⇧ or ⌥ click the page's navigation still counts as that click's.
    static let followedClickWindow: TimeInterval = 2

    /// From the page script: a ⇧ or ⌥ click landed on `url` and the page kept it.
    func modifiedClickFollowed(_ url: URL, mini: Bool, download: Bool) {
        let activation: LinkActivation = mini ? .mini : download ? .download : .page
        followedClick = activation == .page ? nil : (url, activation, Date())
    }

    /// The kept click `url` follows, taken once: same link, within the window.
    func followedActivation(for url: URL?) -> LinkActivation? {
        guard let clicked = followedClick, let url, Date().timeIntervalSince(clicked.at) < Self.followedClickWindow,
              Self.sameAddress(clicked.url, url) else { return nil }
        followedClick = nil
        return clicked.activation
    }

    /// Whether a "Visit anyway" link came from the certificate warning itself: a click in the main frame of the web
    /// view showing it, on the host it warned about.
    static func isClickOnWarning(targetsMainFrame: Bool, sourceIsMainFrame: Bool, sameWebView: Bool, userInitiated: Bool,
                                 pageHost: String?, warnedHost: String?) -> Bool {
        targetsMainFrame && sourceIsMainFrame && sameWebView && userInitiated && warnedHost != nil && pageHost == warnedHost
    }

    /// Whether a restored page is loaded again: a web page fetched with GET, so a form is never sent twice.
    nonisolated static func revalidatesRestoredPage(url: URL?, method: String?, type: WKNavigationType) -> Bool {
        guard type == .backForward, (method ?? "GET").uppercased() == "GET", let scheme = url?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    /// Whether a navigation may land on one of Zigzag's own pages: Zigzag's own load, Back or Forward, or a link
    /// from another of its pages. Back and Forward only when Zigzag started them: a page can call history.back().
    static func mayGoToInternalPage(ownLoad: Bool, ownHistory: Bool, isBackForward: Bool, fromInternalPage: Bool) -> Bool {
        ownLoad || ownHistory || (fromInternalPage && !isBackForward)
    }

    /// Registrable domain by the Public Suffix List (bbc.co.uk; myapp.vercel.app is separate from evil.vercel.app). A
    /// host without one (IP, single label, a suffix itself) is its own site.
    nonisolated static func site(of url: URL) -> String? {
        guard var host = url.host()?.lowercased(), !host.isEmpty else { return nil }
        if host.hasSuffix(".") { host.removeLast() }
        return HostText.registrableDomain(of: host) ?? host
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
        if navigationResponse.isForMainFrame { loadTimings.responded() }
        // A redirect may land on another origin: the door follows the address that is really going to be shown.
        if navigationResponse.isForMainFrame, navigationResponse.canShowMIMEType, let landed = response.url {
            localReceivers = LocalReceiverShim.sync(webView, tab: self, origin: SiteOrigin.of(landed),
                                                    isPrivate: isPrivate, owns: ownsPageScripts, current: localReceivers)
        }
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
        if navigationResponse.isForMainFrame {
            pdfResponseURL = mime == "application/pdf" ? response.url : nil
            pdfResponseName = mime == "application/pdf" ? HistoryStore.suggestedName(of: response) : nil
            pdfResponseTooLarge = mime == "application/pdf" && PDFViewerView.isTooLarge(said: response.expectedContentLength)
        }
        let disposition = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition") ?? ""
        let policy = downloads.decide(mimeType: mime, contentDisposition: disposition.lowercased(), canShowMIMEType: navigationResponse.canShowMIMEType,
                                      isMainFrame: navigationResponse.isForMainFrame,
                                      lastInput: DownloadPolicy.lastInput(in: webView))
        // WebRTC follows the shown page after redirects; a response that isn't shown changes nothing.
        if navigationResponse.isForMainFrame {
            WebRTCProtection.apply(to: webView, for: policy == .allow ? response.url : webView.url, in: self)
        }
        // A file blocked by `DownloadPolicy`, a frame's too: a refused export never goes without a word.
        if policy == .cancel {
            refusedDownload(in: webView, text: navigationResponse.isForMainFrame ? DownloadPolicy.refusedText : DownloadPolicy.refusedFrameText,
                            note: DownloadPolicy.refusedNote(isMainFrame: navigationResponse.isForMainFrame))
        }
        #if DEBUG
        if policy == .download {
            debugLog("download chosen: mime=\(mime) canShow=\(navigationResponse.canShowMIMEType) mainFrame=\(navigationResponse.isForMainFrame) attachment=\(!disposition.isEmpty)")
        }
        #endif
        // A server-sent file (attachment, or a type WebKit can't show) may go to another app. Cancelling here avoids a
        // download row and a blank tab. `decide` already held back a burst of unclicked ones.
        if policy == .download, let target = response.url {
            let filename = DownloadTokens.filename(for: target, suggested: Self.filename(from: disposition) ?? "")
            let wasClicked = downloads.mainFrameWasClicked && navigationResponse.isForMainFrame
            if await handOffIfWanted(target, request: URLRequest(url: target), appliesToLinks: false, webView: webView,
                                     filename: filename, mime: mime,
                                     wasClicked: wasClicked) {
                closeIfOnlyADownload(webView)
                return .cancel
            }
            // Add to Firefox: the clicked file is checked against AMO's API now, so the download knows it's the store's.
            if navigationResponse.isForMainFrame, let click = addonsClick, click.covers(target),
               DownloadPolicy.isExtensionPackage(mimeType: mime, filename: filename) {
                addonsClick = nil
                switch ExtensionStore.addonsInstall(file: target, published: await ExtensionStore.publishedAddonsFile(slug: click.slug)) {
                case .install(let published):
                    addonsInstall = (click, published)
                    // The install sheet is the one question, as on the Chrome Web Store; a kept Block for AMO still wins.
                    if Self.skipsDownloadQuestion(kept: SiteOrigin.of(webView.url ?? target).flatMap { SitePermissions.downloads(origin: $0, tab: self) }) { return policy }
                case .unreachable:
                    if let host = webView.window?.contentView {
                        DownloadManager.noticeCouldNotAdd(String(localized: "Firefox Add-ons didn’t answer, so this extension couldn’t be checked and wasn’t added. Try again in a moment.",
                                                                 comment: "Shown when Add to Firefox on addons.mozilla.org was clicked but the store's API couldn't be reached to check the file."), in: host)
                    }
                    return .cancel
                case .notCurrent:
                    break
                }
            }
            // No rule took it: the site's download permission decides. The request isn't available here and a guess
            // would turn a POST into a GET, so no retry is offered. An unclicked page response never asks; a frame's
            // file asks as the page's would, since WebKit never says whether its frame was clicked.
            let isFrame = !navigationResponse.isForMainFrame
            if await !mayDownload(target, in: webView, asking: wasClicked || isFrame,
                                  frameSites: isFrame ? downloads.frameSites(for: target) : []) { return .cancel }
        }
        return policy
    }

    /// Shows a toast for a blocked download.
    private func refusedDownload(in webView: WKWebView, text: String = DownloadPolicy.refusedText, note: String = DownloadPolicy.refusedNote(isMainFrame: true),
                                 action: (title: String, run: () -> Void)? = nil) {
        Diagnostics.note("Download refused", site: url?.host(), note, isPrivate: isPrivate)
        guard let host = webView.window?.windowController as? PromptHost else { return }
        // Toasts with an action stay longer and can be dismissed.
        host.promptToast(text, symbol: "arrow.down.circle", duration: action == nil ? 3 : 6,
                         action: action, closes: action != nil)
    }

    /// Whether the site may download; false means cancel (a toast explains). Asked once per site: "This time" for the
    /// page, "Always" saved. `retry`: the request to offer again, if repeatable. `frameSites`: a frame's own sites.
    private func mayDownload(_ url: URL, in webView: WKWebView, retry: URLRequest? = nil, asking: Bool = true,
                             frameSites: [String] = []) async -> Bool {
        guard let origin = SiteOrigin.of(webView.url ?? url) else {
            // Local files have no site to ask about. A page without a nameable origin (about:blank, data:) can't
            // download when asking is on; with asking off it downloads as before.
            if SitePermissions.pageWithoutSiteMayDownload(isFile: (webView.url ?? url).isFileURL) { return true }
            refusedDownload(in: webView, text: DownloadPolicy.blockedText,
                            note: "A page with no site of its own tried to save a file")
            DownloadManager.shared.dropFileHandoff(for: url, from: webView)
            return false
        }
        let allowed = await SitePermissions.downloadsAllowed(origin: origin, frameSites: frameSites, window: host?.hostWindow,
                                                             isPrivate: isPrivate, tab: self, asking: asking)
        if !allowed {
            refusedDownload(in: webView, text: DownloadPolicy.blockedText, note: "This site is not allowed to save files",
                            action: askAgain(origin: origin, request: retry, in: webView))
            DownloadManager.shared.dropFileHandoff(for: url, from: webView)
        }
        return allowed
    }

    /// A blocked download's Allow Once. WebKit's refusal is final, so it re-requests through the tab's page (the site's
    /// session) and allows it for the page, like "This time". The result is tracked like any download.
    private func askAgain(origin: String, request: URLRequest?, in webView: WKWebView,
                          keepAnswer: Bool = true) -> (title: String, run: () -> Void)? {
        guard let request, DownloadPolicy.canBeAskedAgain(request) else { return nil }
        return (String(localized: "Allow Once", comment: "Button in the notice saying a site’s download was blocked: asks the site for the file again and saves it."),
                { [weak self, weak webView] in
                    guard let webView else { return }
                    // Allow for this page only, and only when the site question blocked it; a site's Block still
                    // applies.
                    if keepAnswer { SitePermissions.allowThisDownload(origin: origin, tab: self) }
                    webView.startDownload(using: request) { download in
                        DownloadManager.shared.track(download, window: webView.window)
                    }
                })
    }

    /// The filename in a Content-Disposition header (extended or plain).
    nonisolated static func filename(from disposition: String) -> String? {
        if let star = disposition.range(of: "filename*=", options: .caseInsensitive) {
            let rest = disposition[star.upperBound...]
            let value = rest.split(separator: ";", maxSplits: 1).first.map(String.init) ?? ""
            let encoded = value.split(separator: "'", maxSplits: 2).last.map(String.init) ?? value
            return encoded.removingPercentEncoding ?? encoded
        }
        guard let plain = disposition.range(of: "filename=", options: .caseInsensitive) else { return nil }
        var value = disposition[plain.upperBound...].split(separator: ";", maxSplits: 1).first.map(String.init) ?? ""
        value = value.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 { value = String(value.dropFirst().dropLast()) }
        return value.isEmpty ? nil : value
    }

    /// The requesting origin: the frame's if the navigation came from one, else the page's (an ad iframe asks as the
    /// ad).
    private func askingOrigin(_ action: WKNavigationAction, webView: WKWebView) -> String? {
        SiteOrigin.of(action.sourceFrame.securityOrigin) ?? SiteOrigin.of(webView.url ?? self.url)
    }

    /// Runs the first matching rule. True means it took the URL and the navigation is cancelled. Uses this tab's cookie
    /// store and space.
    private func handOffIfWanted(_ url: URL, request: URLRequest, appliesToLinks: Bool, webView: WKWebView,
                                 filename: String? = nil, mime: String = "", wasClicked: Bool = false,
                                 pageOrigin: String? = nil) async -> Bool {
        // Zigzag and extension pages are never handed off. A rule-opened page can't be taken again by its rule.
        guard !openedByRule, !wasOpenedByRule(url), !wasDeclined(url) else { return false }
        guard url.scheme?.lowercased() != HistoryPage.scheme, !Self.isExtensionPage(url) else { return false }
        // Links have no filename; a download's name lets an earlier file-type destination match first.
        let handoffName = appliesToLinks ? "" : (filename ?? DownloadTokens.filename(for: url, suggested: ""))
        guard let rule = DownloadHandoff.firstMatch(url, appliesToLinks: appliesToLinks, filename: handoffName,
                                                    isPrivate: isPrivate, in: profile) else { return false }
        let referrer = request.value(forHTTPHeaderField: "Referer").flatMap { URL(string: $0) } ?? self.url
        var handoff = DownloadHandoff.Request(url: url, referrer: referrer, pageOrigin: pageOrigin ?? SiteOrigin.of(webView.url ?? self.url),
                                              filename: DownloadTokens.filename(for: url, suggested: ""),
                                              mime: mime, space: Library.shared.space(spaceID)?.name ?? "",
                                              dataStore: webView.configuration.websiteDataStore, isPrivate: isPrivate,
                                              window: host?.hostWindow, tab: self, wasClicked: wasClicked)
        let decision = await DownloadHandoff.decide(rule, request: handoff, tab: self, forDownload: !appliesToLinks)
        handoff.place = decision.place
        // Declined for a download: Zigzag keeps the file and the download manager must not ask again.
        if decision.declined {
            ruleDeclinedURL = url
            if !appliesToLinks { declinedRuleDownload = true }
        }
        switch decision.gate {
        case .handOff:
            // A File rule needs the download first: let WebKit make it, and the download manager runs the rule on the
            // saved file when it finishes.
            if DownloadHandoff.defersToSavedFile(rule, forDownload: !appliesToLinks) {
                DownloadManager.shared.expectFileHandoff(rule, request: handoff, from: webView)
                return false
            }
            let outcome = await DownloadHandoff.perform(rule, request: handoff)
            if case .failed = outcome { DownloadHandoff.report(outcome, rule: rule, request: handoff) }
            // A matched rule that didn't take it (declined Open URL) acts as no match; the download manager must not
            // offer it to the same rule again.
            if case .noMatch = outcome {
                if !appliesToLinks { declinedRuleDownload = true }
                return false
            }
            // Close a tab opened only for this link.
            closeIfOnlyADownload(webView)
            return true
        case .browser:
            return false
        case .cancel:
            // Don't Allow: neither loads nor downloads.
            return true
        }
    }

    /// Whether `url` is the last declined handoff address.
    private func wasDeclined(_ url: URL?) -> Bool {
        guard let url, let declined = ruleDeclinedURL else { return false }
        return Self.sameAddress(declined, url)
    }

    /// Whether `url` is the last address a download rule opened.
    private func wasOpenedByRule(_ url: URL?) -> Bool {
        guard let url, let opened = ruleOpenedURL else { return false }
        return Self.sameAddress(opened, url)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        let byRule = openedByRule || wasOpenedByRule(download.originalRequest?.url)
        let declined = declinedRuleDownload || wasDeclined(download.originalRequest?.url)
        openedByRule = false
        declinedRuleDownload = false
        DownloadManager.shared.track(download, window: host?.hostWindow, openedByRule: byRule, rulesAlreadyDeclined: declined)
        closeIfOnlyADownload(webView)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        let byRule = openedByRule || wasOpenedByRule(download.originalRequest?.url)
        let declined = declinedRuleDownload || wasDeclined(download.originalRequest?.url)
        openedByRule = false
        declinedRuleDownload = false
        let store = addonsInstall.flatMap { $0.click.covers(download.originalRequest?.url) ? $0.file : nil }
        addonsInstall = nil
        DownloadManager.shared.track(download, window: host?.hostWindow, openedByRule: byRule, rulesAlreadyDeclined: declined, addonsFile: store)
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
        loadTimings.started(navigation, url: webView.url, isPrivate: isPrivate)
        // A link preview from the page that's going has nothing left to describe, and a hover from it during the
        // load must not bring the preview back.
        hoveredLinkChanged(nil)
        isLeavingPage = true
        // The page is going: a socket it opened to this Mac goes with it.
        localReceivers?.closeAllSockets()
        // Ended while the page is still in its process: the next page may get a new one (#348).
        if Passkeys.available { Passkeys.endRequests(in: webView) {} }
    }

    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        loadTimings.redirected(navigation, to: webView.url)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        Freezes.mark("page start")
        loadTimings.committed(navigation)
        isLeavingPage = false
        // A page swiped away from is replaced: the new one shows in place.
        (webView as? BrowserWebView)?.swipeNavigator.pageArrived()
        DarkPages.pageCommitted(in: webView)
        // A reload asks the site again and keeps the restored history.
        let reloadsRestored = restoredPage == .reloads
        if reloadsRestored {
            restoredPage = nil
            webView.reload()
        }
        // The reload starts as quietly as the restored page would have.
        if !reloadsRestored { startsQuietly = false }
        // Page committed: no fallback needed.
        pendingHTTPFallback = nil
        // The rule-opened page arrived, so its links and downloads are normal again.
        openedByRule = false
        ruleOpenedURL = nil
        ruleDeclinedURL = nil
        declinedRuleDownload = false
        forgetPageErrors()
        // A new document, even at the same address: nothing translated is in it.
        isTranslated = false
        changed.send(.document)
        // A click on the page before doesn't let this one open a pop-up.
        PopupNotice.forgetInput(in: webView)
        // The new page is here: its address shows.
        addressWaitsForCommit = false
        // Before the address updates, so a pinned page isn't marked as moved on.
        noteLanding(webView.url)
        if webView.url != url { followAddress(of: webView) }
        // The page that landed is the page the door is for: it stays for an allowed origin, and a page that went
        // somewhere else has it taken out, so the dev page it became keeps its own fetch, XHR and HMR socket.
        if let landed = webView.url {
            localReceivers = LocalReceiverShim.sync(webView, tab: self, origin: SiteOrigin.of(landed),
                                                    isPrivate: isPrivate, owns: ownsPageScripts, current: localReceivers)
        }
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
        // A page has actually loaded in an everyday browser window: on a fresh start that's browsing, and the
        // session from before gives way (#433). A Mini, a private window or Settings isn't browsing.
        if Self.countsAsBrowsingForSession(isPrivate: isPrivate, isInBrowserWindow: host is BrowserWindowController,
                                            url: webView.url) {
            WindowManager.shared.pageLoaded()
        }
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
            // A new site never keeps the previous icon: the site's cached one, else the globe. A page after an error
            // page drops the warning too.
            if !Self.keepsIcon(from: committedURL, to: url) || showsErrorPage {
                favicon = FaviconStore.shared.cachedIcon(for: url)
                iconSource = nil
                changed.send(.favicon)
            }
            committedURL = url
            // Apply developer tools styles to the new page now that it's known whether it's a development page.
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
            // Error page: show the warning icon.
            if showsErrorPage {
                favicon = Self.immediateIcon(for: url, errorPage: true)
                iconSource = nil
                changed.send(.favicon)
            }
            recordHistory(url, title: webView.title)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Freezes.mark("page loaded")
        loadTimings.finished(navigation)
        // Back, Forward and reload end here too, even where the address stays the same.
        navigatedSinceSave = true
        // The page is all here now: what the developer tools put into it is too.
        if !developer.isUnchanged { applyDeveloperStateToPage() }
        addressWaitsForCommit = false
        noteLanding(webView.url)
        checkForPDF(webView)
        refreshFavicon()
        restorePageState(in: webView)
        // A page has loaded: whatever woke it, the sessionStorage script has had its chance.
        dropSessionScript(from: webView)
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
        // History, Settings and error pages aren't foreign-language pages to translate.
        guard PageTranslator.readsLanguage(of: url, errorPage: url != nil && url == errorShownFor) else {
            if foreignLanguage != nil {
                foreignLanguage = nil
                changed.send(.language)
            }
            return
        }
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
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loadTimings.failed(navigation, error: error as NSError)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loadTimings.failed(navigation, error: error as NSError)
        isLeavingPage = false
        // A swipe's page that never came: the one still showing goes back in place.
        (webView as? BrowserWebView)?.swipeNavigator.pageArrived()
        restoredPage = nil
        addressWaitsForCommit = false
        // Failed load: clear rule-opened and declined state.
        openedByRule = false
        declinedRuleDownload = false
        // Retrying over http; the address stays until that load shows.
        if fallBackToHTTP(after: error as NSError, in: webView) { return }
        // Restore the address of the page still showing.
        if webView.url != url { followAddress(of: webView) }
        // The load that failed took the door with it: the page still showing keeps the one for where it is.
        if let showing = webView.url {
            localReceivers = LocalReceiverShim.sync(webView, tab: self, origin: SiteOrigin.of(showing),
                                                    isPrivate: isPrivate, owns: ownsPageScripts, current: localReceivers)
        }
        handle(error, in: webView)
    }

    /// Not failures: cancelled, frame-load-interrupted (downloads, policy) and media WebKit plays itself (direct .mp4
    /// or .mp3, "plug-in handled load").
    private static func isFailure(_ error: NSError) -> Bool {
        !(error.code == NSURLErrorCancelled || (error.domain == "WebKitErrorDomain" && [102, 204].contains(error.code)))
    }

    /// The error's failing URL, else the tab's.
    private func failingURL(of error: NSError) -> URL? {
        (error.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? url
    }

    /// Retries a scheme-less address over http once instead of the error page (`Tab.fallbackURL`), as other browsers
    /// do, after WebKit finishes this failure. Other failures end the fallback; non-failures (policy cancels) keep it.
    private func fallBackToHTTP(after error: NSError, in webView: WKWebView) -> Bool {
        guard let pending = pendingHTTPFallback, Self.isFailure(error) else { return false }
        pendingHTTPFallback = nil
        let failing = failingURL(of: error)
        let strict = failing?.host().map { StrictTransport.isKnown($0.lowercased(), in: webView.configuration.websiteDataStore) } ?? false
        guard let plain = Self.fallbackURL(for: pending, after: error, failing: failing, strictTransport: strict) else { return false }
        Diagnostics.note("Opened over http", site: failing?.host(), "https: \(Diagnostics.describe(error))", isPrivate: isPrivate)
        DispatchQueue.main.async { [weak self, weak webView] in
            guard let self, let webView, self.webView === webView else { return }
            self.load(plain, by: pending.sender)
        }
        return true
    }

    private func handle(_ error: Error, in webView: WKWebView) {
        let nsError = error as NSError
        guard Self.isFailure(nsError) else { return }
        let failingURL = failingURL(of: nsError)
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
        startsQuietly = true
    }

    func webView(_ webView: WKWebView, respondTo challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let answer = await AuthenticationPrompt.respond(to: challenge, window: promptWindow, store: webView.configuration.websiteDataStore, page: webView,
                                                        tab: isPrivate ? nil : self)
        // With no one there, sign-in and certificate requests are refused, and the app is told.
        let method = challenge.protectionSpace.authenticationMethod
        if isUnattended, answer.0 == .cancelAuthenticationChallenge,
           [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest, NSURLAuthenticationMethodNTLM].contains(method) {
            noteUnanswered(.signIn, challenge.protectionSpace.host)
        }
        if isUnattended, answer.0 == .rejectProtectionSpace, method == NSURLAuthenticationMethodClientCertificate {
            noteUnanswered(.certificate, challenge.protectionSpace.host)
        }
        return answer
    }
}

// MARK: - WKUIDelegate

extension Tab: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let made = newWebView(for: webView, configuration: configuration, navigationAction: navigationAction, windowFeatures: windowFeatures)
        // The new window's first request goes as the site's chosen browser, not asked for twice (#392).
        SiteUserAgents.prepare(made, for: navigationAction.request.url)
        return made
    }

    private func newWebView(for webView: WKWebView, configuration: WKWebViewConfiguration, navigationAction: WKNavigationAction,
                            windowFeatures: WKWindowFeatures) -> WKWebView? {
        // An explicit menu choice wins over a click record.
        if BrowserWebView.pendingDisposition(for: webView) == nil {
            // A ⇧-click the page handles itself arrives as its own `window.open`, whose request carries no modifiers:
            // the click record is what says Zigzag Mini. Native clicks use the same precedence, so Command-Shift stays
            // a tab.
            let activation = newWindowActivation(for: navigationAction.request.url,
                                                 type: navigationAction.navigationType,
                                                 isMainFrame: navigationAction.sourceFrame.isMainFrame,
                                                 modifiers: navigationAction.modifierFlags,
                                                 buttonNumber: navigationAction.buttonNumber)
            if activation == .mini, let url = navigationAction.request.url {
                if openPageHandledMini(url) { return nil }
                host?.tab(self, openURL: url, disposition: .mini)
                return nil
            }
        }
        // Zigzag's own Open in New Tab, New Window or Zigzag Mini always opens; a page's own request needs a click or your say.
        if BrowserWebView.pendingDisposition(for: webView) == nil, !PopupNotice.isClicked(navigationAction, in: webView, isPrivate: isPrivate) {
            // Page pop-up: a saved destination for the site opens without asking, else the banner asks and nothing
            // opens yet. Zigzag pages never open this way.
            guard Self.mayOpenInNewWebView(navigationAction.request.url) else { return nil }
            // A blank `window.open()` counts too, so allowed sites keep the open-blank-then-navigate pattern sign-ins
            // and payments use. WebKit passes a scheme-less URL, not nil.
            let (target, isBlank) = PopupNotice.popupTarget(navigationAction.request.url)
            // Pop-ups route like page links: app URLs ask, and anything the web can't open top-level (data:,
            // javascript:, file) opens nowhere.
            switch PopupNotice.route(target, from: url) {
            case .refuse:
                Diagnostics.note("Refused a page's pop-up", site: url?.host(), "\(target.scheme ?? "no scheme"):", isPrivate: isPrivate)
                return nil
            case .app:
                // Frame pop-ups stay silently blocked, so an iframe ad can't raise an app question.
                guard navigationAction.sourceFrame.isMainFrame else {
                    Diagnostics.note("Blocked a frame's pop-up", site: url?.host(),
                                     "\(target.scheme ?? "no scheme"):", isPrivate: isPrivate)
                    return nil
                }
                openFromPage(target, isClick: false, asker: navigationAction.sourceFrame.securityOrigin)
                return nil
            case .open:
                break
            }
            // A saved destination covers the whole site, including frame and blank pop-ups, but only Allow and Zigzag
            // Mini open those: This Tab or New Tab would navigate without a click.
            if !isPrivate, let stored = PopupNotice.storedAction(origin: SiteOrigin.of(url)) {
                let destination = PopupNotice.destination(for: stored)
                guard PopupNotice.storedDestinationMayOpen(destination, forBlankOrFrame: isBlank || !navigationAction.sourceFrame.isMainFrame) else {
                    return nil
                }
                switch destination {
                case .deny:
                    return nil
                case .automatic:
                    // Legacy allow or Site Controls Allow: plain window.open opens a tab, a sized one a pop-up, as
                    // before the card.
                    return host?.tab(self, createWebViewWith: configuration, for: navigationAction, features: windowFeatures)
                case .viewer:
                    // Return a real window while WebKit still offers it, so `window.opener` keeps working.
                    return PopupWindowController.open(configuration: configuration, features: windowFeatures, parent: webView.window, opener: self)
                case .thisTab, .newTab:
                    if let promptHost = host as? PromptHost {
                        PopupNotice.open(target, action: stored, from: self, in: promptHost)
                    }
                    return nil
                }
            }
            // Only the main frame asks, and only for an address; frame pop-ups are blocked silently and blank windows
            // have nothing to ask about yet.
            guard !isBlank, navigationAction.sourceFrame.isMainFrame else {
                Diagnostics.note("Blocked a frame's or a blank pop-up", site: url?.host(),
                                 "\(target.scheme ?? "no scheme"):", isPrivate: isPrivate)
                return nil
            }
            // For Report a Problem: whether you had just clicked or typed in a page, which WebKit didn't count.
            Diagnostics.note("Pop-up without a click", site: url?.host(),
                             PopupNotice.unclickedNote(inMini: host is MiniWindowController, sinceInput: Date().timeIntervalSince(UndoClock.lastPageInput)),
                             isPrivate: isPrivate)
            return PopupNotice.ask(navigationAction, from: url, isPrivate: isPrivate, tab: self, in: host as? PromptHost,
                                   configuration: configuration, features: windowFeatures)
        }
        // Zigzag's own pages never open as a page's new window: Settings would show over it before anything loaded.
        guard Self.mayOpenInNewWebView(navigationAction.request.url) else {
            _ = BrowserWebView.takePendingDisposition(for: webView)
            return nil
        }
        // A link a rule wants goes straight to its app, never a blank window. Zigzag's Open in New Window or Tab still
        // opens.
        if BrowserWebView.pendingDisposition(for: webView) == nil,
           let url = navigationAction.request.url, PopupNotice.isUserInitiated(navigationAction),
           let rule = DownloadHandoff.firstMatch(url, appliesToLinks: true, isPrivate: isPrivate, in: profile) {
            _ = BrowserWebView.takePendingDisposition(for: webView)
            handOffInNewWindow(rule, url: url, request: navigationAction.request, webView: webView,
                               pageOrigin: askingOrigin(navigationAction, webView: webView),
                               wasClicked: navigationAction.navigationType == .linkActivated)
            return nil
        }
        return host?.tab(self, createWebViewWith: configuration, for: navigationAction, features: windowFeatures)
    }

    /// Rule caught a new-window link; the handoff is async, so no window is created.
    private func handOffInNewWindow(_ rule: DownloadRule, url: URL, request: URLRequest, webView: WKWebView,
                                    pageOrigin: String?, wasClicked: Bool) {
        let referrer = request.value(forHTTPHeaderField: "Referer").flatMap { URL(string: $0) } ?? self.url
        let base = DownloadHandoff.Request(url: url, referrer: referrer, pageOrigin: pageOrigin ?? SiteOrigin.of(webView.url ?? self.url),
                                           filename: DownloadTokens.filename(for: url, suggested: ""),
                                           space: Library.shared.space(spaceID)?.name ?? "",
                                           dataStore: webView.configuration.websiteDataStore, isPrivate: isPrivate,
                                           window: host?.hostWindow, tab: self, wasClicked: wasClicked)
        Task { @MainActor in
            var handoff = base
            let decision = await DownloadHandoff.decide(rule, request: handoff, tab: self)
            handoff.place = decision.place
            switch decision.gate {
            case .handOff:
                let outcome = await DownloadHandoff.perform(rule, request: handoff)
                if case .failed = outcome { DownloadHandoff.report(outcome, rule: rule, request: handoff) }
                // Declined or nowhere to open: open the tab it would have opened, since the window was already refused.
                if case .noMatch = outcome { self.host?.tab(self, openURL: url, disposition: .foregroundTab) }
            case .browser:
                // The window was refused, so open the link in a tab.
                self.host?.tab(self, openURL: url, disposition: .foregroundTab)
            case .cancel:
                break
            }
        }
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
        // No one there to print for.
        guard !isUnattended else { noteUnanswered(.print); completionHandler(); return }
        PagePrinting.printForPage(webView, frame: frame, in: host?.hostWindow, completion: completionHandler)
    }

    /// The same request from older WebKit, which doesn't wait.
    @objc(_webView:printFrame:)
    func webView(_ webView: WKWebView, printFrame frame: AnyObject?) {
        guard !isUnattended else { noteUnanswered(.print); return }
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
    func hoveredLinkChanged(_ url: URL?, title: String? = nil) {
        // The page is going: a hover from it is for a page that won't be here, and must not bring the preview back
        // after the click cleared it.
        guard !isLeavingPage else { return }
        hoveredLink = url
        hoveredLinkTitle = url == nil ? nil : title
        host?.tab(self, hoveringLink: url)
    }

    /// The floating video's Return button. WebKit puts the video back only once its page is on screen, and asks the
    /// browser to show it here (WKUIDelegatePrivate, unpublished). Without it, Return from another tab does nothing.
    @objc(_webViewFullscreenMayReturnToInline:)
    func webViewFullscreenMayReturnToInline(_ webView: WKWebView) {
        host?.tabWantsToBeShown(self)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {
        noteUnanswered(.alert, message)
        await PageDialogs.alert(message: message, frame: frame, window: promptWindow)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
        noteUnanswered(.confirm, message)
        return await PageDialogs.confirm(message: message, frame: frame, window: promptWindow)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo) async -> String? {
        noteUnanswered(.prompt, prompt)
        return await PageDialogs.prompt(message: prompt, defaultText: defaultText, frame: frame, window: promptWindow)
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        // With no window, the panel would open alone mid-screen: no one there, no file.
        guard !isUnattended else { noteUnanswered(.filePicker); return nil }
        return await PageDialogs.openPanel(parameters: parameters, window: host?.hostWindow)
    }

    /// WebKit's own question for location (not public API, but how Safari asks): answered with Zigzag's prompt.
    @objc(_webView:requestGeolocationPermissionForOrigin:initiatedByFrame:decisionHandler:)
    private func webView(_ webView: WKWebView, requestGeolocationPermissionFor origin: WKSecurityOrigin, initiatedBy frame: WKFrameInfo,
                 decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void) {
        Task { decisionHandler(await SitePermissions.requestLocation(origin: origin, window: promptWindow, isPrivate: isPrivate, tab: self)) }
    }

    // The completion-handler form: its Swift async name differs between SDKs, and a near miss is never called.
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType, decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void) {
        // Camera and microphone don't need WebRTC; it's only offered when a page starts a call (`WebRTCProtection`).
        Task { decisionHandler(await SitePermissions.request(origin: origin, type: type, window: promptWindow, isPrivate: isPrivate, tab: self)) }
    }

    /// Screen sharing (Meet, Zoom, Teams). WebKit asks the browser through this unpublished method; the answer
    /// (`DisplayCaptureChoice`) is 2 for macOS's window picker, 1 for its screen picker, 0 for no. Asked every time.
    @objc(_webView:requestDisplayCapturePermissionForOrigin:initiatedByFrame:withSystemAudio:decisionHandler:)
    func webView(_ webView: WKWebView, requestDisplayCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo,
                 withSystemAudio: Bool, decisionHandler: @escaping (Int) -> Void) {
        Task { @MainActor in
            decisionHandler(await SitePermissions.requestDisplayCapture(origin: origin, window: promptWindow, tab: self).rawValue)
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
        // Runs in Zigzag's world, without a user gesture (`runOwnScript`).
        webView.runOwnScript(Self.pdfCheckScript) { [weak self, weak webView] answer in
            MainActor.assumeIsolated {
                guard let self, let webView, webView === self.webView, webView.url == url else { return }
                let contentType = (try? answer.get()) as? String
                // While a PDF still loads, WebKit's page may not say so yet: the response already did.
                guard contentType == "application/pdf" || self.pdfResponseURL == url else {
                    self.showsPDF = false
                    (webView as? BrowserWebView)?.isPDF = false
                    if self.pdfViewer != nil { self.setPDFViewer(nil) }
                    return
                }
                self.showPDF(url, in: webView, userAgent: webView.sentUserAgent, fresh: fresh && self.pdfResponseURL != url)
            }
        }
    }

    /// The PDF's name until it has a title: the response's, else the file's, else the site.
    fileprivate func pdfName(of url: URL) -> String {
        HistoryStore.pdfName(of: url, suggested: pdfResponseURL == url ? pdfResponseName : nil)
    }

    /// Asks the page whether it's a PDF.
    static let pdfCheckScript = "document.contentType"

    /// The page at `url` is a PDF: Zigzag's viewer over it, unless it's showing already (and this isn't a new load).
    private func showPDF(_ url: URL, in webView: WKWebView, userAgent: String?, fresh: Bool) {
        self.showsPDF = true
        (webView as? BrowserWebView)?.isPDF = true
        let showing = self.pdfViewer?.url == url
        // A PDF has no page title, so the last page's would linger: it's named by its file until it says more.
        if !showing {
            self.title = pdfName(of: url)
            self.changed.send(.title)
        }
        // Outside a tab list, a form's reply, or one ours couldn't open (on this page, or one that brought the helper down this
        // session, which a reload would only bring down again): WebKit's own viewer shows it.
        guard !self.isOutsideTabList, self.pageIsGet, !self.pdfFailed.contains(url), !SafePDF.broughtDownTheHelper(url),
              !(self.pdfResponseURL == url && self.pdfResponseTooLarge) else {
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
        // Its PDF's connection to the helper ends with it.
        pdfViewer?.document?.close()
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
