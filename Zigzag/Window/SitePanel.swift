import AppKit
import WebKit

/// A window of one page with no browser window behind it, where Site Controls opens from its strip: Zigzag Mini (#225)
/// and an installed app's window (#356).
@MainActor protocol SitePanelPageHost: AnyObject {
    var tab: Tab { get }
    var overlay: PassthroughView { get }
    var window: NSWindow? { get }
    /// Its extensions listed, their menus working and their popups not: those open from a browser window's address.
    var listsExtensions: Bool { get }
    func copyPageURL(_ sender: Any?)
    func confirmClear(_ kind: WebsiteData.Kind, of tab: Tab)
}

/// Everything about the page you're on, behind one button by the address (#174). Its first page is short: the site,
/// with whether its connection is secure in a small line under its name (#221), a row of quick actions, your
/// extensions to click right there (#215), a line into Permissions (once the site asked), and the few switches that
/// apply to this page. Each of those
/// lines opens a page of its own in the same panel, with a way back. Rarer things (installing the site as an app, clearing its cookies or cache) wait in the
/// ⋯ menu. Changes apply at once.
final class SitePanel: FloatingPanelView {
    override var replacesExtensionPopup: Bool { true }
    private static weak var current: SitePanel?
    static var isOpen: Bool { current?.superview != nil }
    static func isOpen(in window: NSWindow?) -> Bool { isOpen && current?.window === window }
    /// The open panel, for debugging.
    static var shown: SitePanel? { current }
    static func closeCurrent() { current?.close() }
    /// A panel closed: what was chosen in it is settled, for lists of those choices to read again.
    static let closed = Signal<Void>()

    private weak var controller: BrowserWindowController?
    /// Opened in Zigzag Mini (#225) or an installed app's window (#356): its one page, with what a page's own settings
    /// are; what needs a browser window (Reader, translating, extensions' popups, the developer tools) stays there.
    private weak var pageHost: SitePanelPageHost?
    private weak var anchor: NSView?
    /// The button it opened from, shown pressed while it's open: the sidebar's, or a split pane's (#160).
    private weak var opener: IconButton?
    private var monitor: Any?
    private let tab: Tab
    /// A private window's, even on a new tab with no page yet: no extensions there.
    private let isPrivate: Bool
    private let url: URL
    private let site: String
    /// The name the header shows: the site, with its port when it has its own (`init`).
    private var shownName = ""
    /// The page's origin, which its camera, location, notification and pop-up answers are kept under.
    private let origin: String?
    private let isBlank: Bool
    /// The panel is about one page: when it goes to another site (a sign-in redirect), the panel goes too.
    private var pageToken: SignalToken?
    /// Clear cookies when Zigzag quits, which shows or hides Keep cookies while the panel is open (#383).
    private var clearingToken: SignalToken?
    /// Whether this panel describes the page in this tab.
    func describes(_ other: Tab?) -> Bool { other === tab || other == nil && isBlank }
    /// Opened from a split pane's strip, under its address: it belongs to where that strip is.
    private(set) var isFromPane = false
    /// Opened from the sidebar address: aligned with the field's edge.
    private var isAlongAddress = false
    /// Sidebar on the right: aligned with the address's trailing edge.
    private var alignsTrailing = false

    private let icon = FaviconView()
    private let siteName = Label("", font: Tokens.Font.voice(20), color: Tokens.Color.textPrimary)
    /// Over the name, for its tooltip: a label lets the pointer through.
    private let siteNameHover = NSView()
    private let moreButton = IconButton(symbol: "ellipsis", toolTip: String(localized: "More", comment: "Tooltip of the … button in the site panel."))
    private var actionTiles: [PanelTile] = []
    /// Your extensions, on the first page, in reach without another page (#215).
    private(set) var extensionsSection: SiteExtensionsSection?
    /// The developer tools (#141), for a development page that doesn't have them in the bar above it.
    private var developerTiles: [PanelTile] = []
    private let developerLabel = Label.section(String(localized: "Developer", comment: "Section label over the developer tools' tiles in the site panel, on a development site."))
    private var extensionsToken: SignalToken?
    private let siteLabel = Label.section(String(localized: "This Site", comment: "Section label over the site's settings in the site panel."))
    private var rows: [PanelRow] = []
    private let group = PanelGroup()
    /// Whether the connection is secure, small under the site's name, and the way into its certificate (#221).
    private var connectionLine: ConnectionLine?
    /// Why the connection isn't secure, under the site's name, when that isn't plain to see (a certificate let through).
    private let connectionNote: Label = {
        let label = Label("", font: Tokens.Font.small(), color: Tokens.Color.textSecondary)
        label.usesSingleLineMode = false
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.cell?.wraps = true
        label.cell?.truncatesLastVisibleLine = false
        label.isHidden = true
        return label
    }()
    private var permissionsRow: PanelLinkRow?
    /// Zapped element count; opens the list of them.
    private var zappedRow: PanelLinkRow?
    /// The zapped elements, newest first, each with ×, and Restore All under them (#498).
    private let zapsGroup = PanelGroup()
    private var restoreAllRow: PanelLinkRow?
    /// The zaps `zapsGroup` was built from, in zap order, and their names.
    private var listedZaps: [String] = []
    private var listedNames: [String: String] = [:]
    private let zapsHeader = PanelPageHeader(String(localized: "Zapped Elements", comment: "Title of the site panel's page that lists the elements hidden on the site with Zap Element."))
    /// The site's custom CSS, if any; opens Edit Style.
    private var styleRow: PanelLinkRow?
    private let permissionsGroup = PanelGroup()
    private var resetPermissions: PanelLinkRow?
    /// Permissions page for a site that asked for nothing: says so, no Reset (#232).
    private let permissionsEmpty: Label = {
        let label = Label(String(localized: "This site hasn’t asked for anything yet.", comment: "On a site's Permissions page in the site panel when the site hasn't asked for the camera, location, notifications or anything else."),
                          font: Tokens.Font.body(), color: Tokens.Color.textSecondary)
        label.usesSingleLineMode = false
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.cell?.wraps = true
        label.cell?.truncatesLastVisibleLine = false
        label.isHidden = true
        return label
    }()
    private let permissionsHeader = PanelPageHeader(String(localized: "Permissions", comment: "Row in the site panel, and the title of its page: the site's camera, location, notifications and pop-ups."))
    /// The certificate, its own page while it's open.
    private var certificatePage: CertificatePage?
    private let certificateHeader = PanelPageHeader(CertificatePage.title)
    /// A hairline under a page's header while the page has scrolled under it, as a built-in page's header has.
    private let headerEdge = ColorView(color: Tokens.Color.separator)
    private var zoomStepper: ZoomStepper?

    /// The panel's pages: the site at a glance, and one each for what's behind its rows.
    enum Page: String { case main, connection, permissions, zapped }
    private(set) var page = Page.main
    var showsSubpage: Bool { page != .main }
    private let mainBox = FlippedView()
    private let permissionsBox = FlippedView()
    private let zapsBox = FlippedView()

    /// The panel's content, in a sheet that scrolls when the window is too short for it.
    private let scroll = NSScrollView()
    private let content = FlippedView()
    private var contentReady = false
    private var scrollToken: NSObjectProtocol?
    /// The tallest it can be where it opened: down to the window's bottom.
    fileprivate var maxHeight: CGFloat = .greatestFiniteMagnitude

    static let width: CGFloat = 300
    /// How a plain http page is marked, here and in the address bar: one symbol and one wording.
    static let notSecure = String(localized: "Not secure", comment: "How a page loaded over plain http, or with a certificate you chose to trust anyway, is marked, in the site panel and the address bar's tooltip.")
    static let notSecureSymbol = "lock.open.fill"

    /// What the connection line under the site's name says, whether it warns, and why when that isn't plain to see.
    /// `hasCertificate`: false for Zigzag's own warning in place of a page that didn't load, which is never called
    /// secure. A page WebKit loaded over https without reporting its certificate (from a service worker, as Discourse
    /// sites like linux.do are, or from memory) was still checked on the way: it's secure, with no certificate to show.
    static func connection(scheme: String?, onlySecureContent: Bool, certificateException: Bool, hasCertificate: Bool = true) -> (value: String, warns: Bool, reason: String?) {
        let https = scheme?.lowercased() == "https"
        if https, certificateException {
            return (notSecure, true, String(localized: "Its certificate isn’t trusted. You chose to visit it anyway, until you quit Zigzag.", comment: "Under the site's name at the top of the site panel, on a page whose certificate isn't trusted but you chose Visit this site anyway on the warning."))
        }
        if https, !hasCertificate { return (notSecure, true, nil) }
        if https, onlySecureContent { return (String(localized: "Secure connection", comment: "Small, under the site's name at the top of the site panel: the page came over https. Clicking it shows the certificate."), false, nil) }
        if https { return (String(localized: "Partly secure", comment: "Small, under the site's name at the top of the site panel: an https page with some parts loaded over plain http."), true, nil) }
        return (notSecure, true, nil)
    }
    static let pinTitle = String(localized: "Pin to Address", comment: "Item in an extension's menu, and VoiceOver action of its tile in the site panel: gives the extension a button in the address bar.")
    static let unpinTitle = String(localized: "Unpin from Address", comment: "Item in an extension's menu, and VoiceOver action of its tile in the site panel: takes the extension's button out of the address bar.")
    static var pinLimitTip: String { String(localized: "At most \(ExtensionPins.limit) pins. Unpin one first.", comment: "Tooltip of the disabled Pin to Address item in an extension's menu, when the most extensions that can be pinned already are. The number is that limit.") }
    static let minimumWidth: CGFloat = 256
    /// Panel width, narrower only in a small window.
    static func fittingWidth(in overlayWidth: CGFloat) -> CGFloat {
        max(minimumWidth, min(width, overlayWidth - Tokens.Metric.cardInset * 2))
    }
    private var width: CGFloat = SitePanel.width
    private var pad: CGFloat { width < Self.width ? Tokens.Space.x3 : Tokens.Space.x4 }

    #if DEBUG
    /// A panel for `tab` outside any window, for tests.
    static func forTesting(tab: Tab) -> SitePanel? { SitePanel(controller: nil, tab: tab) }
    #endif

    private init?(controller: BrowserWindowController?, pageHost: SitePanelPageHost? = nil, tab asked: Tab?) {
        // With no page (a new tab), it still opens: your extensions are always one click away.
        guard let tab = asked ?? controller.map({ $0.tabManager.selectedTab ?? Tab(url: nil, spaceID: $0.tabManager.currentSpaceID) }) else { return nil }
        let url = tab.url.flatMap { ["http", "https", "webkit-extension"].contains($0.scheme ?? "") ? $0 : nil }
        isBlank = url == nil
        self.controller = controller
        self.pageHost = pageHost
        self.tab = tab
        isPrivate = tab.isPrivate || controller?.tabManager.isPrivate == true
        self.url = url ?? URL(string: "about:blank")!
        site = url.map { ContentBlocker.site(of: $0) ?? $0.host() ?? $0.absoluteString } ?? String(localized: "New Tab", comment: "Name the site panel shows for a new tab with no page.")
        let origin = SiteOrigin.of(url)
        self.origin = origin
        super.init(frame: .zero)
        // Everything scrolls in one sheet when the window is too short for the whole panel.
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.contentView = FlippedClipView()
        scroll.contentView.drawsBackground = false
        scroll.documentView = content
        addSubview(scroll)
        // A page's header is the panel's own, over the sheet that scrolls: its way back and its title stay put (#220).
        [permissionsHeader, zapsHeader, certificateHeader, headerEdge].forEach { addSubview($0) }
        [mainBox, permissionsBox, zapsBox].forEach { content.addSubview($0) }
        contentReady = true
        permissionsHeader.onBack = { [weak self] in self?.show(.main) }
        zapsHeader.onBack = { [weak self] in self?.show(.main) }
        certificateHeader.onBack = { [weak self] in self?.show(.main) }
        scroll.contentView.postsBoundsChangedNotifications = true
        scrollToken = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshHeaderEdge() }
        }
        radius = Tokens.Radius.panel
        icon.image = SiteIcons.icon(for: url, privateStore: tab.privateStore).map(IconChoice.pageIcon) ?? tab.favicon
        // In the app's voice, as a page names itself; a site's name keeps its own spelling. Plain http or a port of
        // its own is named in full, as its answers are its own: localhost:3000 never reads like localhost:3001.
        let web = ["http", "https"].contains(self.url.scheme?.lowercased() ?? "")
        let full = origin.map(SiteOrigin.label).flatMap { $0.contains(":") ? $0 : nil }
        let named = web ? full ?? site : site
        shownName = named
        siteName.attributedStringValue = Tokens.Font.voiceText(named, size: 20)
        // However it's cut to fit, VoiceOver gets the whole name, and so does the pointer (`layoutContent`).
        siteName.setAccessibilityValue(named)
        let address = self.url
        if ["http", "https"].contains(address.scheme ?? "") {
            // The connection, in a few words under the site's name: secure, or not. Only an https page has a
            // certificate to show; plain http just says it's not secure. An extension's own page never crosses the
            // network: no line. A certificate let through on the warning page is not secure, whatever else the page
            // is, and says why.
            let connection = Self.connection(scheme: address.scheme, onlySecureContent: tab.webView?.hasOnlySecureContent ?? true,
                                             certificateException: tab.usesCertificateException,
                                             hasCertificate: !tab.showsErrorPage)
            let opens = address.scheme == "https" && tab.webView?.serverTrust != nil
            connectionLine = ConnectionLine(connection.value, warns: connection.warns, opens: opens) { [weak self] in self?.showCertificate() }
            if let reason = connection.reason {
                connectionNote.stringValue = reason
                connectionNote.isHidden = false
            }
        }
        [icon, siteName, siteNameHover, moreButton].forEach { addSubview($0) }
        if let connectionLine { addSubview(connectionLine) }
        if !connectionNote.isHidden { addSubview(connectionNote) }
        let shownSite = site
        pageToken = tab.changed.observe { [weak self, weak tab] change in
            guard let self else { return }
            // Opened while the page was still loading, the connection wasn't known yet (no certificate): it says what
            // it is once the page has it, without closing and opening the panel again.
            if change == .loading || change == .navigation { self.refreshConnection() }
            guard change == .url, let now = tab?.url else { return }
            if (ContentBlocker.site(of: now) ?? now.host() ?? now.absoluteString) != shownSite || SiteOrigin.of(now) != origin { self.close() }
        }
        let profileID = tab.profile.id
        clearingToken = KeptCookies.clearingChanged.observe { [weak self] profile in
            guard let self, profile == profileID, !self.isBlank,
                  SitePanelRows.rows(self.rowContext).contains(.keepCookies) != self.rows.contains(where: { $0 === self.keepCookiesRow }) else { return }
            self.rebuildRows()
        }
        moreButton.onClick = { [weak self] _ in self?.showMoreMenu() }
        moreButton.isHidden = !canClear && !canBoost && !canSetIcon
        // No page: only your extensions, one click away, the whole panel.
        if isBlank { [icon, siteName, siteNameHover, moreButton].forEach { $0.isHidden = true } }
        buildExtensions()
        if !isBlank {
            buildTiles()
            buildDeveloperTiles()
            buildRows()
        }
        applyPage()
        onLayout = { [weak self] in self?.layoutContent() }
        frame.size = NSSize(width: width, height: layoutContent(dryRun: true))
        setAccessibilityLabel(String(localized: "Site controls for \(site)", comment: "VoiceOver name of the site panel. The site is a domain, like example.com."))
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Showing

    /// Opens the panel under `anchor`, or closes the one open. `tab` is the page it's about: a split pane's, from
    /// its strip (#160); nil is the tab you're in, which in a split is the pane you're in.
    static func toggle(in controller: BrowserWindowController, from anchor: NSView, tab: Tab? = nil) {
        // Open here: the click closes it. Left open in another window, it goes, and this window's opens.
        if let current, current.superview != nil {
            let here = current.window === controller.window
            current.close()
            if here { return }
        }
        guard let panel = SitePanel(controller: controller, tab: tab) else { return }
        controller.closeFloatingPanels()
        panel.anchor = anchor
        panel.isFromPane = Self.paneStrip(of: anchor) != nil
        let overlay = controller.root.overlay
        let anchorFrame = anchor.convert(anchor.bounds, to: overlay)
        // Fixed width, independent of the sidebar (#335).
        let pane = Self.paneStrip(of: anchor) != nil
        let aboveThePage = anchor.isDescendant(of: controller.root.topBar)
        let inset = Tokens.Metric.cardInset
        panel.width = Self.fittingWidth(in: overlay.bounds.width)
        if controller.root.chromeSidebarShown, !controller.root.isSidebarFloatingVisible, !aboveThePage, !pane {
            // The same glass panel as Downloads over the sidebar's lane, with the tabs under it faded back.
            panel.recedes = [controller.sidebar.list]
        }
        // Aligned with the address field's outer edge.
        let alongAddress = !aboveThePage && !pane && anchorFrame.minX >= 0
        panel.isAlongAddress = alongAddress
        panel.alignsTrailing = alongAddress && controller.root.sidebarOnRight
        let x = aboveThePage || pane || panel.alignsTrailing ? anchorFrame.maxX - panel.width : anchorFrame.minX
        panel.frame.origin = NSPoint(x: SitePanelSizing.x(x, alongAddress: alongAddress, inset: inset, width: panel.width, overlayWidth: overlay.bounds.width),
                                     y: anchorFrame.maxY + 4)
        // Never past the window's bottom: what doesn't fit scrolls.
        panel.maxHeight = SitePanelSizing.maxHeight(overlayHeight: overlay.bounds.height, top: panel.frame.minY)
        panel.frame.size = NSSize(width: panel.width, height: panel.fittedHeight)
        controller.root.overlay.addSubview(panel)
        panel.needsLayout = true
        // Out of the button that opened it (the site controls, at the address's right end), not a corner. From a
        // pane's ⋯, out of ⋯.
        let opener = (anchor as? PaneAddressView)?.siteControls ?? (anchor as? IconButton) ?? controller.sidebar.address.siteControlsButton
        panel.opener = opener
        if panel.frame.width > 0 {
            let b = opener.convert(opener.bounds, to: controller.root.overlay)
            panel.growsFrom = CGPoint(x: min(max((b.midX - panel.frame.minX) / panel.frame.width, 0), 1), y: 0)
        } else {
            panel.growsFrom = CGPoint(x: 0.5, y: 0)
        }
        panel.present(arrival: .pop)
        opener.isSelected = true
        current = panel
        // Only its own window: keys and clicks in Settings or another window are theirs.
        panel.monitor = TouchPress.addMonitor(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak panel] event in
            guard let panel else { return event }
            return panel.handle(event)
        }
    }

    /// Opens the panel for the page of Zigzag Mini or an app's window under its strip's Site Controls button, or
    /// closes the one open (#225, #356).
    static func toggle(in host: SitePanelPageHost, from button: IconButton) {
        if let current, current.superview != nil {
            let here = current.window === host.window
            current.close()
            if here { return }
        }
        guard let panel = SitePanel(controller: nil, pageHost: host, tab: host.tab) else { return }
        panel.anchor = button
        // Over the page, under the button's end, as from the address above a browser window's page; kept in the window.
        let overlay = host.overlay
        let inset = Tokens.Metric.cardInset
        panel.width = Self.fittingWidth(in: overlay.bounds.width)
        let b = button.convert(button.bounds, to: overlay)
        let x = min(b.maxX - panel.width, overlay.bounds.width - inset - panel.width)
        panel.frame.origin = NSPoint(x: max(inset, x), y: max(b.maxY, 0) + 4)
        panel.maxHeight = SitePanelSizing.maxHeight(overlayHeight: overlay.bounds.height, top: panel.frame.minY)
        panel.frame.size = NSSize(width: panel.width, height: panel.fittedHeight)
        overlay.addSubview(panel)
        panel.needsLayout = true
        panel.opener = button
        panel.growsFrom = CGPoint(x: min(max((b.midX - panel.frame.minX) / panel.frame.width, 0), 1), y: 0)
        panel.present(arrival: .pop)
        button.isSelected = true
        current = panel
        panel.monitor = TouchPress.addMonitor(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak panel] event in
            guard let panel else { return event }
            return panel.handle(event)
        }
    }

    /// A click or key while it's open, in its own window only: Esc goes back from one of its pages, or closes it; a
    /// click outside it and its button closes it. A menu open over it takes Esc and the click that closes it.
    private func handle(_ event: NSEvent) -> NSEvent? {
        guard event.window === window, MenuPanel.current == nil else { return event }
        if event.type == .keyDown {
            if event.keyCode == 53 {
                if showsSubpage { show(.main) } else { close() }
                return nil
            }
            return event
        }
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        let onAnchor = anchor.map { $0.bounds.contains($0.convert(event.locationInWindow, from: nil)) } ?? false
        if !inside && !onAnchor { close() }
        return event
    }

    /// The split pane's strip a view is in, if any.
    private static func paneStrip(of view: NSView) -> PaneHeaderView? {
        var next: NSView? = view
        while let v = next {
            if let strip = v as? PaneHeaderView { return strip }
            next = v.superview
        }
        return nil
    }

    func close() {
        pageToken = nil
        clearingToken = nil
        if let scrollToken { NotificationCenter.default.removeObserver(scrollToken) }
        scrollToken = nil
        extensionsToken = nil
        opener?.isSelected = false
        if let monitor { TouchPress.removeMonitor(monitor) }
        monitor = nil
        if Self.current === self { Self.current = nil }
        dismiss()
        Self.closed.send()
    }

    // MARK: Content

    /// What this page can do right now, as named tiles: sharing, the link, a screenshot and translating always, Reader
    /// and Picture in Picture when the page has them. The steady ones come first, so they never move.
    private func buildTiles() {
        // Zigzag Mini and an app's window (`pageHost`) have the page's own actions: sharing, the link and Picture in Picture.
        guard controller != nil || pageHost != nil else { return }
        let readerOn = controller?.isShowingReader ?? false
        // (symbol, caption, full name for the tooltip and VoiceOver, on, action, the menu bar item whose keys the tooltip shows)
        var specs: [(String, String, String, Bool, () -> Void, Selector?)] = []
        let share = String(localized: "Share", comment: "Action in the site panel: shares the page.")
        specs.append(("square.and.arrow.up", share, share, false, { [weak self] in
            guard let self else { return }
            let opener = self.opener, url = self.url
            self.close()
            if let controller = self.controller { controller.sharePage(nil); return }
            guard let opener else { return }
            NSSharingServicePicker(items: [CleanLink.clean(url) as NSURL]).show(relativeTo: opener.bounds, of: opener, preferredEdge: .minY)
        }, #selector(BrowserWindowController.sharePage(_:))))
        let copyLink = String(localized: "Copy Link", comment: "Action in the site panel: copies the page's address.")
        specs.append(("link", copyLink, copyLink, false, { [weak self] in
            guard let self else { return }
            if let controller = self.controller { controller.copyLink(self.url, title: self.tab.displayTitle) } else { self.pageHost?.copyPageURL(nil) }
            self.close()
        }, #selector(BrowserWindowController.copyPageURL(_:))))
        if let controller, controller.capture.canBegin, !readerOn {
            specs.append(("camera.viewfinder",
                          String(localized: "Capture", comment: "Action in the site panel, under its icon: takes a screenshot of the whole page."),
                          String(localized: "Capture an Area, an Element or the Whole Page", comment: "Tooltip of the Capture action in the site panel; its keyboard shortcut follows."),
                          false, { [weak self] in
                guard let self, let controller = self.controller else { return }
                self.close()
                controller.capture.begin()
            }, #selector(BrowserWindowController.takePageScreenshot(_:))))
        }
        // Always here, as in the menu, for when the offer went by or never came: a page that's already in your
        // language says so, and a translated one goes back to its original.
        let translate = String(localized: "Translate", comment: "Action in the site panel: translates the page.")
        if controller != nil { specs.append(("translate",
                      tab.isTranslated ? String(localized: "Original", comment: "Action in the site panel, under its icon: shows the translated page as it was.") : translate,
                      tab.isTranslated ? String(localized: "Show Original", comment: "Tooltip of the Original action in the site panel.") : translate,
                      tab.isTranslated, { [weak self] in self?.controller?.translatePage(); self?.close() }, #selector(BrowserWindowController.translatePage(_:)))) }
        if controller != nil, tab.isArticle || readerOn {
            specs.append(("doc.plaintext", String(localized: "Reader", comment: "Action in the site panel, under its icon: opens or closes Reader."),
                          readerOn ? String(localized: "Hide Reader", comment: "Tooltip of the Reader action in the site panel, while Reader is on.")
                                   : String(localized: "Show Reader", comment: "Tooltip of the Reader action in the site panel."),
                          readerOn, { [weak self] in self?.controller?.toggleReader(); self?.close() }, #selector(BrowserWindowController.toggleReader(_:))))
        }
        let floating = tab.webView?.isPictureInPictureActive ?? false
        if floating || tab.webView?.canTogglePictureInPicture ?? false {
            specs.append(("pip", String(localized: "Float", comment: "Action in the site panel, under its icon: plays the page's video in Picture in Picture."),
                          floating ? String(localized: "Back to Page", comment: "Tooltip of the Float action in the site panel, while the video floats: puts it back in its page.")
                                   : String(localized: "Picture in Picture", comment: "Tooltip of the Float action in the site panel."),
                          floating, { [weak self] in
                guard let self else { return }
                if let controller = self.controller { controller.togglePictureInPicture(nil) } else { self.tab.webView?.togglePictureInPicture() }
                self.close()
            }, controller != nil ? #selector(BrowserWindowController.togglePictureInPicture(_:)) : nil))
        }
        actionTiles = specs.map { symbol, caption, title, on, run, action in
            // The panel's own short action words; the tooltip and VoiceOver keep the full name, the tooltip with its keys.
            let tile = PanelTile(symbol: symbol, caption: caption)
            tile.toolTip = action.map { Shortcuts.tooltip(title, for: $0) } ?? title
            tile.setAccessibilityLabel(title)
            tile.isOn = on
            tile.onClick = { _ in run() }
            addSubview(tile)
            return tile
        }
    }

    /// The console, inspecting and reloading as tiles, where a development page doesn't have them above it: Tools above the page is off, or
    /// the page is in a split, whose panes keep their headers. They come after the page's actions, which never move.
    private func buildDeveloperTiles() {
        guard let controller else { return }
        guard tab.isDevelopment, !controller.showsDeveloperBarTools(for: tab) else { return }
        let tools = DeveloperTool.tiles.filter { $0.isOffered(for: tab, isPrivate: isPrivate) }
        developerTiles = tools.map { tool in
            let tile = PanelTile(symbol: tool.symbol, caption: tool.caption)
            tile.toolTip = Shortcuts.tooltip(tool.title, for: tool.action)
            tile.setAccessibilityLabel(tool.title)
            if tool == .console {
                tile.badge = DeveloperTool.errorBadge(tab.pageErrorCount)
                tile.setAccessibilityValue(DeveloperTool.errorValue(tab.pageErrorCount))
            }
            tile.onClick = { [weak self] _ in
                guard let self, let controller = self.controller else { return }
                self.close()
                tool.run(in: controller)
            }
            addSubview(tile)
            return tile
        }
        if !developerTiles.isEmpty { addSubview(developerLabel) }
    }

    /// Only a web site has a cache and cookies of its own to clear: not a file, an extension's page or a new tab.
    private var canClear: Bool { !tab.isPrivate && (url.scheme == "http" || url.scheme == "https") }

    /// Boosts (zapping) for web pages in browser windows, private too; never Zigzag pages, error pages, Reader or PDFs.
    private var canBoost: Bool {
        controller != nil && !isBlank && ZapPicker.canZap(tab) && controller?.isShowingReader != true
    }

    /// Site icons for web pages in browser windows (private ones keep them per window); not in Zigzag Mini, which has
    /// no sidebar.
    private var canSetIcon: Bool { controller != nil && SiteIcons.site(of: url) != nil }

    static let siteIconTitle = String(localized: "Change Site Icon…", comment: "Item in the … menu of the site panel: opens the icon choices for the whole site, used by every tab, pinned tab and favorite on it.")

    /// Opens the site icon grid where the panel was: beside the sidebar when opened from its address, so affected tabs
    /// stay visible.
    private func chooseSiteIcon() {
        guard let controller else { return }
        let tab = tab, top = frame.origin, beside = isAlongAddress
        close()
        controller.chooseSiteIcon(for: tab, at: top, besideSidebar: beside)
    }

    static let zapTitle = String(localized: "Zap Element", comment: "Item in the … menu of the site panel: pick elements on the page to hide on this site, like Arc's Zap.")

    /// Menu with Clear Cache, Clear Cookies and boosts.
    private func showMoreMenu() {
        guard canClear || canBoost || canSetIcon else { return }
        var entries: [MenuPanel.Entry] = []
        if let controller, WebAppInstallSheet.canInstall(tab, isPrivate: controller.tabManager.isPrivate) {
            entries.append(.item(.init(title: WebAppInstallSheet.title) { [weak self, weak controller] in
                guard let self, let controller else { return }
                let tab = self.tab
                self.close()
                WebAppInstallSheet.show(for: tab, in: controller)
            }))
            entries.append(.separator)
        }
        // Developer Mode for the site, as View › Developer has it (#141).
        if let controller, DeveloperTool.site.isOffered(for: tab, isPrivate: controller.tabManager.isPrivate) {
            entries.append(.item(.init(title: DeveloperTool.siteShortTitle(listed: DevelopmentSites.covers(url)), symbol: DeveloperTool.modeSymbol,
                                       shortcut: Shortcuts.keys(for: DeveloperTool.site.action)) { [weak self, weak controller] in
                guard let self, let controller else { return }
                let url = self.url
                self.close()
                controller.setDeveloperMode(for: url, on: !DevelopmentSites.covers(url))
            }))
            entries.append(.separator)
        }
        // Boosts: hide elements on the site.
        if canBoost {
            entries.append(.item(.init(title: Self.zapTitle, symbol: "scope") { [weak self] in self?.startZapping() }))
            entries.append(.item(.init(title: SiteStyleSheet.title, symbol: "paintbrush") { [weak self] in self?.editStyle() }))
        }
        // A site-wide icon (#310).
        if canSetIcon {
            entries.append(.item(.init(title: Self.siteIconTitle, symbol: SidebarMenus.Symbol.changeIcon) { [weak self] in self?.chooseSiteIcon() }))
        }
        if canClear, canBoost || canSetIcon { entries.append(.separator) }
        guard canClear else { MenuPanel.show(entries, from: moreButton); return }
        // Clearing asks first: cookies sign you out of the site, and neither can be taken back.
        MenuPanel.show(entries + [
            .item(.init(title: String(localized: "Clear Cookies and Data…", comment: "Item in the … menu of the site panel: clears the site's cookies and what it keeps on this Mac, after asking.")) { [weak self] in self?.clear(.cookies) }),
            .item(.init(title: String(localized: "Clear Cache for This Site…", comment: "Item in the … menu of the site panel.")) { [weak self] in self?.clear(.cache) }),
        ], from: moreButton)
    }

    // MARK: Pages

    /// Goes to one of the panel's pages: the panel stays where it is and takes the page's height.
    func show(_ next: Page) {
        guard next != page else { return }
        if page == .connection {
            certificatePage?.removeFromSuperview()
            certificatePage = nil
        }
        page = next
        applyPage()
        resize()
        scroll.contentView.scroll(to: .zero)
        let shown: [NSView?] = [mainBox, permissionsBox, zapsBox, certificatePage, pinnedHeader]
        for view in shown.compactMap({ $0 }) where !view.isHidden && view.superview != nil {
            Tokens.Motion.present(view, from: .inPlace, entering: true)
        }
    }

    /// Only the page's own views show.
    private func applyPage() {
        mainBox.isHidden = page != .main
        permissionsBox.isHidden = page != .permissions
        permissionsHeader.isHidden = page != .permissions
        zapsBox.isHidden = page != .zapped
        zapsHeader.isHidden = page != .zapped
        certificateHeader.isHidden = page != .connection
        refreshHeaderEdge()
    }

    /// The page's header, which stays put at the top while the page under it scrolls: none on the first page, which
    /// scrolls whole.
    private var pinnedHeader: PanelPageHeader? {
        switch page {
        case .main: nil
        case .permissions: permissionsHeader
        case .zapped: zapsHeader
        case .connection: certificateHeader
        }
    }

    /// The top of the panel a page's header keeps out of the scrolling.
    private var headerBand: CGFloat { pinnedHeader.map { SitePanelSizing.headerBand(pad: pad, header: $0.height) } ?? 0 }

    private func refreshHeaderEdge() {
        headerEdge.isHidden = pinnedHeader == nil || scroll.contentView.bounds.minY <= 0
    }

    /// The window grew or shrank under it (full screen, a resize): it takes the room there is now, and what doesn't fit
    /// scrolls.
    override func resize(withOldSuperviewSize oldSize: NSSize) {
        guard let superview, maxHeight < .greatestFiniteMagnitude else { return }
        // Narrower now: as narrow as it must be, and back inside the window's right edge, as it opened.
        let inset = Tokens.Metric.cardInset
        width = Self.fittingWidth(in: superview.bounds.width)
        if isAlongAddress, let anchor, anchor.window === window {
            // Keep alignment with the address after a resize.
            let along = anchor.convert(anchor.bounds, to: superview)
            frame.origin.x = SitePanelSizing.x(alignsTrailing ? along.maxX - width : along.minX, alongAddress: true, inset: inset,
                                               width: width, overlayWidth: superview.bounds.width)
        } else {
            frame.origin.x = max(inset, min(frame.minX, superview.bounds.width - inset - width))
        }
        frame.size.width = width
        maxHeight = SitePanelSizing.maxHeight(overlayHeight: superview.bounds.height, top: frame.minY)
        resize()
    }

    /// The connection line again, as the page now is: a page that finished loading has its certificate.
    private func refreshConnection() {
        guard let old = connectionLine, ["http", "https"].contains(url.scheme ?? "") else { return }
        let connection = Self.connection(scheme: url.scheme, onlySecureContent: tab.webView?.hasOnlySecureContent ?? true,
                                         certificateException: tab.usesCertificateException,
                                         hasCertificate: !tab.showsErrorPage)
        let opens = url.scheme == "https" && tab.webView?.serverTrust != nil
        let line = ConnectionLine(connection.value, warns: connection.warns, opens: opens) { [weak self] in self?.showCertificate() }
        guard line.debugText != old.debugText || (connection.reason ?? "") != (connectionNote.isHidden ? "" : connectionNote.stringValue) else { return }
        line.frame = old.frame
        replaceSubview(old, with: line)
        connectionLine = line
        if let reason = connection.reason {
            connectionNote.stringValue = reason
            if connectionNote.superview == nil { addSubview(connectionNote) }
            connectionNote.isHidden = false
        } else {
            connectionNote.isHidden = true
        }
        needsLayout = true
        resize()
    }

    /// The certificate, read from the trust WebKit checked the page with.
    private func showCertificate() {
        guard page != .connection, let trust = tab.webView?.serverTrust else { return }
        let certificate = CertificatePage()
        // Choosing another certificate in the chain changes how much there is to show (#220).
        certificate.onResize = { [weak self] in self?.resize() }
        content.addSubview(certificate)
        certificatePage = certificate
        show(.connection)
        // WebKit checked it already; its answer is read off the main thread, as one never checked is checked there.
        nonisolated(unsafe) let checked = trust
        Task { [weak self, weak certificate] in
            let details = await Task.detached { CertificateDetails.from(checked) }.value
            guard let self, let certificate, self.certificatePage === certificate else { return }
            certificate.details = details
            self.resize()
        }
    }

    private func resize() {
        frame.size.height = fittedHeight
        needsLayout = true
    }

    /// The panel takes the height of what changed in it. Folding or opening the extensions slides like a drawer
    /// (the drawer role): the panel's edge and everything under the section move together, from where they are.
    private func resize(opening: Bool) {
        guard window != nil, !Tokens.Motion.isFromKey else { resize(); return }
        let height = fittedHeight
        Tokens.Motion.animate(SiteExtensionsSection.drawer(opening: opening), moves: true) {
            self.frame.size.height = height
            self.needsLayout = true
            self.layoutSubtreeIfNeeded()
        }
    }

    /// As tall as its content, up to `maxHeight`.
    fileprivate var fittedHeight: CGFloat {
        let band = headerBand
        // A long list of zaps scrolls under its header instead of growing the panel to the window's bottom.
        let most = page == .zapped ? min(maxHeight, band + SitePanelSizing.zapListHeight) : maxHeight
        return SitePanelSizing.fit(band: band, body: layoutContent(dryRun: true) - band, maxHeight: most).height
    }

    /// The site at a glance goes in its own page; the other pages add theirs where they're built.
    override func addSubview(_ view: NSView) {
        if contentReady { mainBox.addSubview(view) } else { super.addSubview(view) }
    }

    #if DEBUG
    /// sitepage <main|connection|permissions>: goes to that page, as its row or back button does.
    func debugPage(_ arg: String) {
        // sitepage zap | restore: Zap Element in ⋯, or Restore All.
        if arg == "zap" { startZapping(); return }
        if arg == "restore" { restoreZaps(); return }
        // sitepage unzap <index>: × on the zapped element at that row, newest first.
        if arg.hasPrefix("unzap "), let index = Int(arg.dropFirst(6)), boost.zaps.reversed().indices.contains(index) {
            unzap(Array(boost.zaps.reversed())[index]); return
        }
        if arg == "style" { editStyle(); return }
        if arg == "icon" { MenuPanel.current?.close(animated: false); chooseSiteIcon(); return }
        if arg == "more" { showMoreMenu(); return }
        guard let next = Page(rawValue: arg) else { return }
        if next == .connection { showCertificate() } else { show(next) }
    }

    /// sitecert <index>: a certificate of the chain chosen on the certificate page, as a click on its row.
    func debugCertificate(_ index: Int) { certificatePage?.debugChoose(index) }

    /// What the panel shows, for checking it without looking: its page, and its rows' names, top to bottom.
    var debugState: [String: Any] {
        ["site": site, "page": page.rawValue, "certificate": certificatePage?.debugState ?? [:],
         "connection": connectionLine?.debugText ?? "",
         "links": [permissionsRow, zappedRow, styleRow].compactMap { $0 }.filter { !$0.isHidden }.map(\.debugTitle),
         "rows": rows.map(\.debugTitle), "permissions": permissionsGroup.rows.map(\.debugTitle), "zaps": zapsGroup.rows.map(\.debugTitle),
         "extensions": extensionsSection?.debugState ?? [:],
         "zoom": zoomStepper.map { ZoomLevels.percent($0.zoom) } ?? "",
         "scroll": ["panel": frame.height, "viewport": scroll.frame.height, "body": content.frame.height, "offset": scroll.contentView.bounds.minY],
         // Width the widest row needs on one line.
         "fit": (rows + permissionsGroup.rows).map(\.debugWants).max().map { $0 + pad * 2 } ?? 0,
         "linksFit": [permissionsRow, zappedRow, styleRow].compactMap { $0 }.filter { !$0.isHidden }.map(\.debugWants).max().map { $0 + pad * 2 } ?? 0,
         "place": ["x": frame.minX, "width": frame.width, "window": superview?.bounds.width ?? 0,
                   "anchor": anchor.flatMap { a in superview.map { a.convert(a.bounds, to: $0).minX } } ?? CGFloat(-1)]]
    }

    /// sitecompat on|off: the Compatibility mode switch.
    func debugCompatibility(_ arg: String) {
        rows.first { $0.debugTitle.hasPrefix(Self.compatibilityTitle + ":") }?.debugChoose(arg == "on" ? 1 : 0)
    }

    /// sitedark <automatic|on|off|force>: chooses in the Dark page row's dropdown.
    func debugDark(_ arg: String) {
        guard let index = DarkPages.SiteChoice.allCases.firstIndex(where: { $0.rawValue == arg }) else { return }
        darkRow?.debugChoose(index)
    }

    /// sitejs allowed|blocked: picks from the JavaScript dropdown.
    func debugJavaScript(_ arg: String) {
        guard ["allowed", "blocked"].contains(arg) else { return }
        javaScriptRow?.debugChoose(arg == "allowed" ? 0 : 1)
    }

    /// sitezoom in|out|reset: the Zoom row's buttons.
    func debugZoom(_ arg: String) { zoomStepper?.debugPress(arg) }

    /// sitepermrow <row> <ask|allow|block>: chooses in that permission row's dropdown; sitepermrow reset presses
    /// Reset Permissions.
    func debugPermissionRow(_ arg: String) {
        let f = arg.split(separator: " ").map(String.init)
        if f.first == "reset" {
            if let click = NSEvent.mouseEvent(with: .leftMouseUp, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                              eventNumber: 0, clickCount: 1, pressure: 0) { resetPermissions?.onClick?(click) }
            return
        }
        guard f.count == 2, let row = Int(f[0]), permissionsGroup.rows.indices.contains(row), permissionKinds.indices.contains(row),
              let wanted = ["ask": PermissionChoice.ask, "allow": .allow, "block": .block][f[1]],
              let choice = permissionKinds[row].choices.firstIndex(of: wanted) else { return }
        permissionsGroup.rows[row].debugChoose(choice)
    }

    /// <index> <row title>: picks that choice in the named This Site row's menu ("1 Open in").
    func debugChooseRow(_ arg: String) {
        let f = arg.split(separator: " ", maxSplits: 1).map(String.init)
        guard f.count == 2, let index = Int(f[0]), let row = rows.first(where: { $0.debugTitle.hasPrefix(f[1] + ":") }) else { return }
        row.debugChoose(index)
    }

    /// <row title>: opens that This Site row's dropdown; "action <row title>" runs its first action instead (Custom…).
    func debugRowMenu(_ arg: String) {
        let action = arg.hasPrefix("action ")
        let title = action ? String(arg.dropFirst(7)) : arg
        guard let dropdown = rows.first(where: { $0.debugTitle.hasPrefix(title + ":") })?.debugDropdown else { return }
        if action { MenuPanel.current?.close(animated: false); dropdown.actions.first?.run() } else { dropdown.openMenu() }
    }
    #endif

    #if DEBUG
    /// sitextcount <n>: the extensions shown again over and over until there are n, for a look at many without
    /// installing them all; 0 shows them as they are. The copies only show.
    static var debugExtensionCount = 0
    #endif

    /// Extensions are listed in a browser window and an app's window.
    private var listsExtensions: Bool { controller != nil || pageHost?.listsExtensions == true }

    /// Where the store, Settings and an extension's settings open: this browser window, or from an app's window, one
    /// brought forward.
    private func windowToOpenIn() -> BrowserWindowController? {
        if let controller { return controller }
        guard pageHost != nil else { return nil }
        let target = MiniWindowController.browserWindow()
        target.window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
        return target
    }

    /// An extension's menu, from a browser window or, about this page, from an app's window.
    @available(macOS 15.4, *)
    private func extensionMenu(for context: WKWebExtensionContext) -> NSMenu? {
        if let controller { return controller.extensionMenu(for: context) }
        guard let pageHost else { return nil }
        let profile = tab.profile
        return BrowserWindowController.extensionMenu(for: context, profile: profile, tab: tab, isPrivate: isPrivate, over: pageHost.overlay,
                                                     openOptions: { [weak self] options in
            guard let target = self?.windowToOpenIn() else { return }
            target.tabManager.newTab(url: options, spaceID: target.tabManager.space(for: profile), title: context.webExtension.displayName)
        }, pins: { menu, id in menu.addItem(BrowserWindowController.pinItem(for: id, installs: profile.installs)) })
    }

    /// Your extensions, as their toolbar buttons are: the icon, the badge, and whether each works on this site.
    private func buildExtensions() {
        // In a private window, only those allowed there, as in Chrome's incognito (ExtensionHost.actions).
        // In Zigzag Mini, none: an extension's popup opens from a browser window's address. An app's window lists
        // them with their menus (#356).
        guard #available(macOS 15.4, *), listsExtensions, let host = tab.extensionHost else { return }
        // A blank private window's stand-in tab isn't private itself: the window says it.
        let actions = host.actions(for: tab).filter { PrivateAccess.sees(isPrivate: isPrivate, allowed: $0.context.hasAccessToPrivateData) }
        if isPrivate, actions.isEmpty { return }
        let installs = tab.profile.installs
        let offHere = !isBlank && (ExtensionStore.extensionsOffSites(in: tab.profile).contains(site) || compatible)
        let web = ["http", "https"].contains(url.scheme ?? "")
        let tab = tab, url = url
        var items: [SiteExtensionsSection.Item] = actions.map { action in
            let context = action.context
            // Only a web page can be out of an extension's reach; one that never asks for any site works anywhere.
            let wants = web && context.webExtension.allRequestedMatchPatterns.contains { $0.matches(url) }
            let access = web ? SiteExtensionAccess.of(offHere: offHere, hasAccess: context.hasAccess(to: url, in: tab), wantsSite: wants,
                                                      clickAccess: installs.siteAccess(action.id) == .click) : .runs
            return SiteExtensionsSection.Item(id: action.id, name: context.webExtension.displayName ?? action.label, label: action.label,
                                              icon: action.icon, badge: action.badge,
                                              needsAttention: action.attention != nil, access: access,
                                              run: { [weak self] view in
                                                  guard let self else { return }
                                                  // No popup without a browser window: the click opens its menu.
                                                  guard let controller = self.controller else { (view as? InteractiveView)?.showContextMenu(); return }
                                                  host.performAction(action, tab: self.tab, in: controller)
                                              },
                                              menu: { [weak self] in self?.extensionMenu(for: context) })
        }
        // By name, so a tile is always where it was, whatever order they were loaded in.
        items.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        #if DEBUG
        if Self.debugExtensionCount > 0, !items.isEmpty {
            let real = items
            items = (0..<Self.debugExtensionCount).map { i in
                let item = real[i % real.count]
                guard i >= real.count else { return item }
                return .init(id: "\(item.id)-\(i)", name: item.name, label: item.label, icon: item.icon, badge: i % 5 == 3 ? "\(i)" : "", needsAttention: false,
                             access: i % 4 == 2 ? .blocked : item.access, run: { _ in }, menu: { nil })
            }
        }
        #endif
        let profile = Library.shared.hasManyProfiles && !tab.isPrivate ? Library.shared.directory.profile(tab.profile.id)?.displayName : nil
        let section = SiteExtensionsSection(items: items, isWhole: isBlank, profile: profile, get: { [weak self] in
            // In a space of the page's profile, so what's added is that profile's.
            if let self, let target = self.windowToOpenIn() {
                target.tabManager.newTab(url: ExtensionStore.webStoreURL, spaceID: self.controller == nil ? target.tabManager.space(for: self.tab.profile) : nil)
            }
            self?.close()
        }, manage: { [weak self] in
            // Every extension, its sites and its pins: Settings › Extensions.
            guard let self, let controller = self.windowToOpenIn() else { return }
            self.close()
            SettingsPage.open(.extensions, in: controller)
        })
        section.wirePins(state: { id in installs.pins.contains(id) ? .pinned : installs.canPin(id) ? .unpinned : .atLimit },
                         toggle: { id in installs.togglePin(id) },
                         title: { id in installs.pins.contains(id) ? Self.unpinTitle : Self.pinTitle })
        section.onResize = { [weak self] opening in self?.resize(opening: opening) }
        addSubview(section)
        extensionsSection = section
        extensionsToken = ExtensionCenter.changed.observe { [weak section] in section?.refreshPins() }
    }

    // What the rows of This Site say they're set to.
    private static let onHere = String(localized: "On for this site", comment: "Under a row's name in the site panel's This Site group, what it's set to: on.")
    private static let offHere = String(localized: "Off for this site", comment: "Under a row's name in the site panel's This Site group, what it's set to: off.")

    /// Compatibility mode (#497): its row's name, here and in Settings › Privacy › Sites.
    static let compatibilityTitle = String(localized: "Compatibility mode", comment: "Row in the site panel's This Site group and in Settings › Privacy › Sites: for a site that doesn't work right, turns off extensions, ad blocking, cookie banners and zapped elements on it, keeping those choices for later.")
    static let compatibilityTip = String(localized: "Turns off extensions, ad blocking, cookie banners and zapped elements on this site. Your choices for them come back when you turn it off.", comment: "Tooltip of the Compatibility mode row in the site panel.")
    /// Under a row compatibility mode sets aside.
    static let offInCompatibility = String(localized: "Off in compatibility mode", comment: "Under a row in the site panel (Ad blocking, Cookie banners, Extensions) while Compatibility mode is on for the site: it's off, and its own choice comes back when that's turned off.")
    /// At the end of the zapped elements and Custom style rows while compatibility mode is on.
    static let offShort = String(localized: "compatibility.off", defaultValue: "Off", comment: "Short, at the end of a row in the site panel (3 zapped, Custom style) while Compatibility mode is on for the site: those changes aren't applied.")

    /// A Site Controls button in the accent while compatibility mode is on for its page's site, as the star is while pinned.
    static func markCompatibility(_ button: IconButton, url: URL?) {
        let on = SiteCompatibility.isOn(for: url)
        button.tint = on ? Brand.Theme.for(button).accent : Tokens.Color.icon
        button.toolTip = on ? String(localized: "Site Controls, compatibility mode on", comment: "Tooltip of the Site Controls button by the address while Compatibility mode is on for the page's site.")
            : PaneHeaderView.siteControlsTitle
        button.setAccessibilityValue(on ? compatibilityTitle : nil)
    }

    /// Compatibility mode is on for this page's site.
    private var compatible: Bool { !isBlank && SiteCompatibility.isOn(for: url) }

    /// A choice in the Dark page row's dropdown.
    static func title(of choice: DarkPages.SiteChoice) -> String {
        switch choice {
        case .automatic: String(localized: "Follow Setting", comment: "A choice in the Dark page dropdown of the site panel: the site follows Settings › Appearance › Dark pages.")
        case .on: String(localized: "dark-page.on", defaultValue: "Always", comment: "A choice in the Dark page dropdown of the site panel: this site's pages are drawn dark.")
        case .off: String(localized: "dark-page.off", defaultValue: "Off", comment: "A choice in the Dark page dropdown of the site panel: this site's pages are never drawn dark, and are asked for their light look.")
        case .force: String(localized: "Force Dark", comment: "A choice in the Dark page dropdown of the site panel: this site is drawn dark even where it looks dark on its own, for a site that leaves parts of itself light.")
        }
    }

    /// What the Dark page row says under its name: what dark pages do on this page now. The dropdown beside it says
    /// what was chosen, so On and Off say nothing more, unless the page is dark on its own; the words are short, to fit
    /// beside the dropdown.
    enum DarkStatus: Equatable {
        /// Nothing: the choice says it.
        case none
        /// Automatic, and Settings has it drawn dark now, or doesn't.
        case nowOn, nowOff
        /// On, and the site is dark on its own: left as it is.
        case darkAlready
        /// Force.
        case alwaysDark
        /// The developer tools chose this tab's look: the site's choice waits.
        case developerTools

        static func of(_ choice: DarkPages.SiteChoice, wanted: Bool, native: Bool, developerLook: Bool) -> DarkStatus {
            if developerLook { return .developerTools }
            if choice == .force { return .alwaysDark }
            if wanted, native { return .darkAlready }
            if choice == .automatic { return wanted ? .nowOn : .nowOff }
            return .none
        }

        var text: String? {
            switch self {
            case .none: nil
            case .nowOn: String(localized: "Now on", comment: "Short, it fits beside a dropdown. Under Dark page in the site panel's This Site group, set to Automatic: Settings › Appearance › Dark pages has this site drawn dark now.")
            case .nowOff: String(localized: "Now off", comment: "Short, it fits beside a dropdown. Under Dark page in the site panel's This Site group, set to Automatic: Settings › Appearance › Dark pages leaves this site as it is now.")
            case .darkAlready: String(localized: "Dark already", comment: "Short, it fits beside a dropdown. Under Dark page in the site panel's This Site group: dark pages are on, and the site has a dark look of its own, so it's left as it is.")
            case .alwaysDark: String(localized: "Always dark", comment: "Short, it fits beside a dropdown. Under Dark page in the site panel's This Site group, set to Force Dark: the site is drawn dark even where it looks dark on its own.")
            case .developerTools: String(localized: "Developer tools", comment: "Short, it fits beside a dropdown. Under Dark page in the site panel's This Site group, on a development site whose page was set to Light or Dark with the developer tools: they set this tab's look, and dark pages leave it alone.")
            }
        }
    }

    /// The JavaScript row's choices (#282).
    static let javaScriptAllowed = String(localized: "javascript.allowed", defaultValue: "Allow", comment: "A choice in the JavaScript dropdown, in the site panel and in Settings › Privacy: pages run their scripts.")
    static let javaScriptNotAllowed = String(localized: "javascript.not-allowed", defaultValue: "Block", comment: "A choice in the JavaScript dropdown, in the site panel and in Settings › Privacy: pages don't run their scripts.")

    /// JavaScript row subtitle explaining a broken-looking page: off by the setting, or a site choice that differs from
    /// it. Nil when it matches the setting.
    static func javaScriptStatus(url: URL, tab: Tab) -> String? {
        let allowed = SiteJavaScript.allows(url, in: tab)
        if SiteJavaScript.isOwn(url, in: tab) {
            if !allowed { return String(localized: "Off here", comment: "Short, it fits beside a dropdown. Under JavaScript in the site panel's This Site group: this site's own choice turns its scripts off.") }
            return SiteJavaScript.isAllowed ? nil : String(localized: "On here", comment: "Short, it fits beside a dropdown. Under JavaScript in the site panel's This Site group: this site runs its scripts, though Settings › Privacy › JavaScript is set to Block.")
        }
        return allowed ? nil : String(localized: "Every site", comment: "Short, it fits beside a dropdown. Under JavaScript in the site panel's This Site group, set to Block: that's Settings › Privacy › JavaScript, for every site, and this site has no choice of its own.")
    }

    static func darkStatus(tab: Tab, url: URL) -> String? {
        DarkStatus.of(DarkPages.siteChoice(for: url), wanted: DarkPages.wants(url), native: tab.darkPage?.native == true,
                      developerLook: tab.developerInEffect.appearance != .followsMac).text
    }

    /// Which rows apply to this page, as `SitePanelRows` decides from what the page is.
    private var rowContext: SitePanelRows.Context {
        var context = SitePanelRows.Context()
        context.isWeb = ["http", "https"].contains(url.scheme ?? "")
        context.isPrivate = isPrivate
        context.adBlocking = ContentBlocker.isEnabled
        // Once a consent pop-up was found on the page, or a choice was made for the site (#175).
        context.cookieBanners = CookieBanners.applies(to: url)
            && (CookieBanners.outcome(in: tab.webView, site: site) != nil || CookieBanners.choice(for: url) != nil)
        // JavaScript has a row on every web page, so Permissions is never empty.
        let hasPermissions = origin.map { !SitePermissions.shown(origin: $0, isPrivate: isPrivate || tab.isPrivate).isEmpty } ?? false
        context.hasPermissions = hasPermissions || context.isWeb
        context.siteChoices = KeepAwake.isOffered(for: url, isPrivate: isPrivate)
        context.clearsCookiesOnQuit = KeptCookies.clearsOnQuit(in: tab.profile.id)
        // Offered on a page with a video, or once chosen; the setting is in Settings › Tabs.
        context.fullScreen = PageFullScreen.isOffered(for: url, isPrivate: isPrivate)
            && (PageFullScreen.choice(for: url) != nil || tab.webView.map({ PageVideos.shared.frames(in: $0).contains { !$0.videos.isEmpty } }) == true)
        // Translating is a browser window's (`translatePage`).
        context.foreignLanguage = controller != nil && tab.foreignLanguage != nil
        // This site's own scripts may reach a program listening on this Mac, once Settings allows it at all.
        context.localApps = context.isWeb && !isPrivate && tab.profile.getsYourData && origin != nil && LocalReceivers.isEnabled
        context.coveredPage = controller?.isShowingReader == true || tab.pdfViewer != nil || tab.webView == nil
        context.manySpaces = Library.shared.yourSpaces.count > 1 && SiteRoutes.site(of: url) != nil
        context.userAgent = Tab.addonsPage(url) == nil
        return context
    }

    /// The full-screen row's name, here and in Settings › Privacy › Sites: on, a video's full screen stays in the window.
    static var fullScreenTitle: String {
        String(localized: "Keep full screen in the window", comment: "Row in the site panel's This Site group and in Settings › Privacy › Sites: a video's full screen on this site fills the page's area in the window instead of the whole screen.")
    }

    /// Under the full-screen row, what full screen does on this site now (#385).
    static func fullScreenStatus(_ on: Bool) -> String {
        on ? String(localized: "Videos fill the page, not the screen", comment: "Under Keep full screen in the window in the site panel, while it's on: a video's full screen on this site fills the page's area in the window.")
            : String(localized: "Videos fill your screen", comment: "Under Keep full screen in the window in the site panel, while it's off: a video's full screen on this site covers the whole screen.")
    }

    /// The Dark page row, while there is one.
    private weak var darkRow: PanelRow?
    /// The Keep cookies row, while there is one.
    private weak var keepCookiesRow: PanelRow?
    /// The JavaScript row, while there is one.
    private weak var javaScriptRow: PanelRow?

    private func buildRows() {
        rows = []
        zoomStepper = nil
        keepCookiesRow = nil
        let compatible = self.compatible
        // Each is offered only where it does something (`SitePanelRows`). The choices kept for a site (ad blocking,
        // dark pages, keeping tabs awake) aren't offered in a private window: its site would be kept in Settings ›
        // Privacy › Sites. Its tabs still follow the ones made elsewhere.
        for kind in SitePanelRows.rows(rowContext) {
            switch kind {
            case .zoom:
                // The page's zoom as it is: in a private window that's its own, which isn't saved for the site.
                let stepper = ZoomStepper()
                stepper.zoom = tab.webView?.pageZoom ?? ZoomLevels.zoom(for: url)
                stepper.onChange = { [weak self] zoom in
                    guard let self else { return }
                    self.tab.webView?.pageZoom = zoom
                    if !self.tab.isPrivate && !self.isPrivate { ZoomLevels.set(zoom, for: self.url) }
                }
                zoomStepper = stepper
                rows.append(.custom(String(localized: "Zoom", comment: "Row in the site panel's This Site group."), control: stepper))
            case .adBlocking:
                let title = String(localized: "Ad blocking", comment: "Row in the site panel's This Site group.")
                if compatible { rows.append(.overridden(title)); break }
                let blocked = !ContentBlocker.isAllowed(on: url)
                rows.append(.toggle(title, on: blocked, status: { $0 ? Self.onHere : Self.offHere }) { [weak self] on in
                    guard let self else { return }
                    ContentBlocker.setAllowed(!on, on: self.url)
                    self.tab.reload()
                })
            case .cookieBanners:
                // Cookie banners (#175), for this site alone. What was done says so quietly, under its name.
                let title = String(localized: "Cookie banners", comment: "Row in the site panel's This Site group: whether Zigzag answers this site's cookie consent pop-ups with no.")
                if compatible { rows.append(.overridden(title)); break }
                let banner = CookieBanners.outcome(in: tab.webView, site: site)
                let rejected = String(localized: "Rejected on this site", comment: "Under Cookie banners in the site panel's This Site group: Zigzag said no to the cookies the site's consent pop-up asked for.")
                let hidden = String(localized: "Hidden on this site", comment: "Under Cookie banners in the site panel's This Site group: the site's cookie notice was only hidden, since there was nothing to say no to.")
                let handledNow = CookieBanners.handles(url)
                rows.append(.toggle(title, on: handledNow, status: { on in
                                        guard on, on == handledNow else { return on ? Self.onHere : Self.offHere }
                                        return banner == .rejected ? rejected : banner == .hidden ? hidden : Self.onHere
                                    }) { [weak self] on in
                    guard let self else { return }
                    CookieBanners.setChoice(on, for: self.url)
                    if let webView = self.tab.webView { CookieBanners.forget(in: webView) }
                    self.tab.reload()
                })
            case .compatibility:
                // One switch for a site that breaks (#497): the rows it sets aside say so, and keep their choices.
                let row = PanelRow.toggle(Self.compatibilityTitle, on: compatible, status: { $0 ? Self.onHere : Self.offHere }) { [weak self] on in
                    guard let self else { return }
                    SiteCompatibility.set(on, for: self.url)
                    self.tab.reload()
                    // After the switch has moved, the rows it overrides show it.
                    DispatchQueue.main.asyncAfter(deadline: .now() + Tokens.Motion.state) { [weak self] in self?.rebuildAll() }
                }
                row.toolTip = Self.compatibilityTip
                rows.append(row)
            case .darkPage:
                // Dark pages for this site alone (#134): Automatic follows Settings, On and Off hold whatever it says,
                // Force darkens it even where it looks dark on its own. Under the name, what that means here now.
                let tab = tab, url = url
                let choices = DarkPages.SiteChoice.allCases
                let row = PanelRow.choice(String(localized: "Dark page", comment: "Row in the site panel's This Site group: draws this site's pages dark."),
                                    options: choices.map(Self.title(of:)), selected: choices.firstIndex(of: DarkPages.siteChoice(for: url)) ?? 0,
                                    status: { _ in Self.darkStatus(tab: tab, url: url) }) { [weak self] index in
                    guard let self else { return }
                    DarkPages.setSiteChoice(choices[index], for: self.url)
                }
                darkRow = row
                rows.append(row)
            case .keepAwake:
                // The site's tabs never sleep in the background (TabSleep, EnergyWatch).
                rows.append(.toggle(String(localized: "Keep tabs awake", comment: "Row in the site panel's This Site group: this site's tabs never go to sleep in the background to save memory."),
                                    on: KeepAwake.isOn(for: url), status: { $0 ? Self.onHere : Self.offHere }) { [weak self] on in
                    guard let self else { return }
                    KeepAwake.set(on, for: self.url)
                })
            case .keepCookies:
                // Clear Cookies… and quitting leave the site's cookies alone (#334).
                let row = PanelRow.toggle(String(localized: "Keep cookies", comment: "Row in the site panel's This Site group: clearing every site's cookies, or clearing them when Zigzag quits, leaves this site's alone, so you stay signed in."),
                                    on: KeptCookies.keeps(url, in: tab.profile.id), status: { $0 ? Self.onHere : Self.offHere }) { [weak self] on in
                    guard let self else { return }
                    KeptCookies.set(on, for: self.url, in: self.tab.profile.id, isPrivate: self.isPrivate || self.tab.isPrivate)
                }
                keepCookiesRow = row
                rows.append(row)
            case .userAgent:
                rows.append(userAgentRow())
            case .fullScreenFills:
                // Full screen in the page's own area instead of the whole screen (#168), for this site alone.
                rows.append(.toggle(Self.fullScreenTitle,
                                    on: PageFullScreen.fills(for: url) == .page, status: Self.fullScreenStatus) { [weak self] on in
                    guard let self else { return }
                    PageFullScreen.setChoice(on ? .page : .screen, for: self.url)
                })
            case .openIn:
                rows.append(openInRow())
                if let rule = Library.shared.siteRoute(for: url) {
                    let edit = IconButton(symbol: "slider.horizontal.3", size: .compact, toolTip: String(localized: "Edit Space Rule…", comment: "Edit the winning rule from Site Controls."))
                    edit.onClick = { [weak self] _ in
                        guard let self, let host = self.controller?.window?.contentView else { return }
                        self.close()
                        SiteRouteSheet.edit(rule, in: host)
                    }
                    rows.append(.custom(String(localized: "Edit Space Rule…", comment: "Edit the winning rule from Site Controls."), control: edit))
                }
            case .localApps:
                // This site's own scripts may reach a program listening on this Mac (LocalReceivers): a switch, never
                // a question the page can raise. Off until it is turned on here.
                guard let origin else { break }
                rows.append(.toggle(String(localized: "Apps on this Mac", comment: "Row in the site panel's This Site group: lets this site's own scripts talk to a program listening on this Mac."),
                                    on: SitePermissions.localReceivers(origin: origin),
                                    status: { $0 ? Self.onHere : Self.offHere }) { on in
                    SitePermissions.setLocalReceivers(on, origin: origin)
                })
            case .alwaysTranslate:
                guard let language = tab.foreignLanguage else { break }
                let name = PageTranslator.name(of: language)
                let title = String(localized: "Always translate \(name)", comment: "Row in the site panel's This Site group: pages in this language are translated as they open, on every site. The name is a language's, like English.")
                let always = String(localized: "As pages open, on every site", comment: "Under Always translate <language> in the site panel's This Site group, while it's on.")
                let asked = String(localized: "Only when you ask", comment: "Under Always translate <language> in the site panel's This Site group, while it's off: pages are translated only when asked.")
                rows.append(.toggle(title, status: { $0 ? always : asked }, on: PageTranslator.translatesAlways(language)) { [weak self] on in
                    PageTranslator.setTranslatesAlways(on, language)
                    if on, self?.tab.isTranslated == false { self?.controller?.translatePage() }
                })
            }
        }
        if group.superview == nil { addSubview(group) }
        group.rows = rows
        group.isHidden = rows.isEmpty
        siteLabel.isHidden = rows.isEmpty
        if siteLabel.superview == nil { addSubview(siteLabel) }
        buildPermissions()
        buildBoostRows()
    }

    /// The browser the site is told it's in (#392): Default, a preset, or one typed in Custom…; choosing reloads.
    private func userAgentRow() -> PanelRow {
        let tab = tab, url = url
        let now = SiteUserAgents.choice(for: url)
        let choices = SiteUserAgents.offered(with: now)
        let custom = DropdownButton.Action(title: now?.isCustom == true ? SiteUserAgents.editCustomAction : SiteUserAgents.customAction, symbol: nil) { [weak self] in
            guard let self, let host = (self.controller?.window ?? self.pageHost?.window)?.contentView else { return }
            self.close()
            SiteUserAgents.showCustomSheet(for: url, in: host, tab: tab)
        }
        return PanelRow.choice(SiteUserAgents.title, options: choices.map { $0?.title ?? SiteUserAgents.defaultTitle },
                               selected: choices.firstIndex(of: now) ?? 0, actions: [custom]) { index in
            SiteUserAgents.choose(choices[index], for: url, in: tab)
        }
    }

    /// Permissions page: a row per permission asked this session or with a saved answer, with Ask, Allow and Block.
    /// Answers are per origin, so another port or scheme has its own. A call (Meet, Zoom, Teams) can have camera and
    /// microphone rows; embedded calls count too. Nothing asked: no page and no row to it.
    private func buildPermissions() {
        var permissionRows: [PanelRow] = []
        permissionKinds = []
        javaScriptRow = nil
        if let origin {
            let tab = tab
            for permission in SitePermissions.shown(origin: origin, isPrivate: isPrivate || tab.isPrivate) {
                let choices = permission.choices
                let now = choice(permission, origin: origin)
                // WebRTC applies at load: choosing reloads (`WebRTCProtection.choose`); private windows keep it per
                // tab.
                permissionRows.append(.choice(permission.title, options: choices.map(\.title), selected: choices.firstIndex(of: now) ?? 0) { [weak self] index in
                    if permission == .webRTC {
                        WebRTCProtection.choose(choices[index] == .allow, origin: origin, in: tab)
                    } else {
                        SitePermissions.setChoice(choices[index], for: permission, origin: origin)
                    }
                    self?.refreshPermissionsRow()
                })
                permissionKinds.append(permission)
            }
        }
        // Whether extensions run here; when off, tiles above dim and say so (#215). It's a site permission, so it's
        // listed here. Only once extensions could run here or were turned off here before.
        if #available(macOS 15.4, *), listsExtensions, !isPrivate, !isBlank, tab.extensionHost != nil,
           ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
           !(extensionsSection?.items.isEmpty ?? true) || ExtensionStore.extensionsOffSites(in: tab.profile).contains(site) {
            let profile = tab.profile
            let enabled = !ExtensionStore.extensionsOffSites(in: profile).contains(site)
            let title = String(localized: "Extensions", comment: "Row in the site panel's Permissions page: whether extensions run on this site.")
            let row = compatible ? PanelRow.overridden(title) : PanelRow.toggle(title, on: enabled, status: { $0 ? Self.onHere : Self.offHere }) { [weak self] on in
                guard let self else { return }
                var sites = ExtensionStore.extensionsOffSites(in: profile)
                if on { sites.remove(self.site) } else { sites.insert(self.site) }
                ExtensionStore.setExtensionsOffSites(sites, in: profile)
                self.tab.reload()
            }
            permissionRows.append(row)
        }
        // JavaScript isn't a WebKit permission but belongs here: Allow or Block, overriding Settings › Privacy
        // › JavaScript. Applies at load, so choosing reloads; private windows keep it per tab.
        if ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            let tab = tab, url = url
            let allowed = SiteJavaScript.allows(url, in: tab)
            let row = PanelRow.choice(String(localized: "JavaScript", comment: "Row in the site panel's Permissions page: whether the site's pages may run their scripts. A name: keep it as it is."),
                                      options: [Self.javaScriptAllowed, Self.javaScriptNotAllowed], selected: allowed ? 0 : 1,
                                      status: { _ in Self.javaScriptStatus(url: url, tab: tab) }) { index in
                SiteJavaScript.choose(index == 0, for: url, in: tab)
            }
            permissionRows.append(row)
            javaScriptRow = row
        }
        if permissionsGroup.superview == nil { permissionsBox.addSubview(permissionsGroup) }
        permissionsGroup.rows = permissionRows
        // WebRTC's row while protection is on reflects the setting, not the site: listed below the empty note, with no
        // Reset.
        let own = permissionKinds.filter { isOwn($0) }
        if permissionsEmpty.superview == nil { permissionsBox.addSubview(permissionsEmpty) }
        permissionsEmpty.isHidden = !own.isEmpty || javaScriptRow != nil
        if resetPermissions == nil, let origin {
            let row = PanelLinkRow(String(localized: "Reset Permissions", comment: "Row under a site's permissions in the site panel: forgets every answer given to the site, so it asks again.")) { [weak self] in
                SitePermissions.reset(origin: origin)
                self?.tab.permissionAnswers.forget()
                PopupNotice.forgetAnswers(origin: origin)
                self?.tab.webRTCHere[origin] = nil
                self?.rebuildRows()
                // Nothing left to show there.
                self?.show(.main)
            }
            permissionsBox.addSubview(row)
            resetPermissions = row
        }
        resetPermissions?.isHidden = own.isEmpty
        if permissionsRow == nil, origin != nil {
            let row = PanelLinkRow(permissionsHeader.title, value: "", goes: true) { [weak self] in self?.show(.permissions) }
            addSubview(row)
            permissionsRow = row
        }
        refreshPermissionsRow()
    }

    /// The Permissions row says what was chosen, in a few words ("2 allowed"), and is there only once there's something.
    private func refreshPermissionsRow() {
        guard let origin, let row = permissionsRow else { return }
        let shown = SitePermissions.shown(origin: origin, isPrivate: isPrivate || tab.isPrivate)
        let web = ["http", "https"].contains(url.scheme?.lowercased() ?? "")
        row.isHidden = shown.isEmpty && !web
        // Only the site's own answers: WebRTC blocked by the setting says nothing about this site.
        let own = shown.filter { isOwn($0) }
        var choices = own.map { choice($0, origin: origin) }
        // The site's own JavaScript and extension choices count too, so JavaScript off never shows as Ask.
        if web, SiteJavaScript.isOwn(url, in: tab) { choices.append(SiteJavaScript.allows(url, in: tab) ? .allow : .block) }
        if web, !isPrivate, ExtensionStore.extensionsOffSites(in: tab.profile).contains(site) { choices.append(.block) }
        row.value = choices.isEmpty ? "" : PermissionChoice.summary(choices)
        row.shortValue = choices.isEmpty ? "" : PermissionChoice.shortSummary(choices)
        needsLayout = true
    }

    /// Open in (#286): the space this site always opens in, or Any space. A subdomain of a listed site shows and
    /// changes that site's choice; otherwise the page's site is used.
    private func openInRow() -> PanelRow {
        let spaces = Library.shared.yourSpaces
        let route = Library.shared.siteRoute(for: url)
        let site = SiteRoutes.site(of: url) ?? self.site
        let selected = route.flatMap { route in spaces.firstIndex { $0.id == route.spaceID }.map { $0 + 1 } } ?? 0
        return .choice(String(localized: "Open in", comment: "Destination space in Site Controls."),
                       options: [Self.anySpace] + spaces.map(\.name), selected: selected,
                       status: { _ in route?.scopeDescription }) { [weak self] index in
            guard let self else { return }
            if index > 0, spaces.indices.contains(index - 1) {
                let updated = SiteRoutes.assigning(url, site: site, to: spaces[index - 1].id, in: Library.shared.siteRoutes)
                Library.shared.saveRoute(updated)
            } else if let route { Library.shared.removeRoute(route.id) }
            rebuildRows()
        }
    }

    static var anySpace: String {
        String(localized: "Any Space", comment: "The first choice of Open in, in the site panel and in Settings › Spaces: the site opens in whatever space the link is in, as usual.")
    }

    private func rebuildRows() {
        buildRows()
        resize()
    }

    /// Rows and extension tiles again, after a change that touches both.
    private func rebuildAll() {
        extensionsSection?.removeFromSuperview()
        extensionsSection = nil
        extensionsToken = nil
        buildExtensions()
        rebuildRows()
    }

    // MARK: Boosts

    /// The site's boosts, including a private window's.
    private var boost: SiteBoost { SiteBoosts.boost(for: url, privateStore: tab.privateStore) }

    private func startZapping() {
        guard let controller else { return }
        let tab = tab
        close()
        ZapPicker.start(in: tab, controller: controller)
    }

    private func editStyle() {
        guard let controller else { return }
        let tab = tab
        close()
        SiteStyleSheet.show(for: tab, in: controller)
    }

    /// "3 zapped", which opens the list of them with Restore All, and Custom style, once the site has them.
    private func buildBoostRows() {
        guard canBoost else { return }
        if zappedRow == nil {
            let row = PanelLinkRow("", goes: true) { [weak self] in self?.show(.zapped) }
            addSubview(row)
            zappedRow = row
        }
        if restoreAllRow == nil {
            let row = PanelLinkRow(Self.restoreAllTitle) { [weak self] in self?.restoreZaps() }
            zapsBox.addSubview(row)
            restoreAllRow = row
        }
        if zapsGroup.superview == nil { zapsBox.addSubview(zapsGroup) }
        if styleRow == nil {
            let row = PanelLinkRow(String(localized: "Custom style", comment: "Row in the site panel, there while the site has CSS of your own: opens Edit Style. Its value says Edit…."),
                                   value: Self.editStyleValue) { [weak self] in self?.editStyle() }
            addSubview(row)
            styleRow = row
        }
        refreshBoostRows()
    }

    static let editStyleValue = String(localized: "Edit…", comment: "At the end of the Custom style row in the site panel: opens the sheet to change the site's CSS.")

    static let restoreAllTitle = String(localized: "Restore All", comment: "Under the list of elements zapped on the site, on its page in the site panel: shows them all again.")

    private func refreshBoostRows() {
        let zaps = boost.zaps
        zappedRow?.titleText = SiteBoosts.zapped(zaps.count)
        zappedRow?.isHidden = zaps.isEmpty
        styleRow?.isHidden = !boost.hasStyle
        zappedRow?.value = compatible ? Self.offShort : ""
        styleRow?.value = compatible ? Self.offShort : Self.editStyleValue
        if zappedRow != nil, listedZaps != zaps || listedNames != boost.names {
            let boost = boost
            listedZaps = zaps
            listedNames = boost.names
            zapsGroup.rows = zaps.reversed().map { selector in
                PanelRow.zap(selector, name: boost.name(forZap: selector)) { [weak self] in self?.unzap(selector) }
            }
        }
        needsLayout = true
    }

    private func restoreZaps() {
        guard let site = SiteBoosts.site(of: url) else { return }
        SiteBoosts.restoreZaps(forSite: site, privateStore: tab.privateStore)
        PageBoosts.refresh(tab)
        refreshBoostRows()
        // Nothing left to list.
        if page == .zapped { show(.main) } else { resize() }
    }

    /// × on one zapped element: shows it again on the page now and on later visits.
    private func unzap(_ selector: String) {
        guard let site = SiteBoosts.site(of: url) else { return }
        ZapPicker.unzap(selector, site: site, in: tab)
        refreshBoostRows()
        if boost.zaps.isEmpty, page == .zapped { show(.main) } else { resize() }
    }

    /// Permissions of the Permissions page rows, top to bottom.
    private var permissionKinds: [SitePermission] = []

    /// The site has its own answer, not just the setting (a private tab's WebRTC choice counts).
    private func isOwn(_ permission: SitePermission) -> Bool {
        guard let origin else { return false }
        return SitePermissions.isOwn(permission, origin: origin, here: tab.webRTCHere[origin])
    }

    /// A permission row's value: WebRTC as this tab has it, including a private window's choice.
    private func choice(_ permission: SitePermission, origin: String) -> PermissionChoice {
        permission == .webRTC ? WebRTCProtection.choice(origin: origin, in: tab) : SitePermissions.choice(permission, origin: origin)
    }

    /// Asks first: cookies sign you out of the site, and neither can be taken back.
    private func clear(_ kind: WebsiteData.Kind) {
        let tab = tab
        close()
        if let controller { controller.confirmClear(kind, of: tab) } else { pageHost?.confirmClear(kind, of: tab) }
    }

    // MARK: Layout

    /// A page's header at the top, and under it the sheet that scrolls, as tall as the page's body.
    private func layoutContent() {
        let band = headerBand
        let body = layoutContent(dryRun: false) - band
        if let header = pinnedHeader {
            header.frame = NSRect(x: pad, y: pad, width: width - pad * 2, height: header.height)
            headerEdge.frame = NSRect(x: 0, y: band - Tokens.Metric.hairline, width: bounds.width, height: Tokens.Metric.hairline)
        }
        scroll.frame = NSRect(x: 0, y: band, width: bounds.width, height: max(0, bounds.height - band))
        content.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(body, scroll.frame.height))
        for box in [mainBox, permissionsBox, zapsBox] { box.frame = content.bounds }
        refreshHeaderEdge()
    }

    @discardableResult
    /// The site's name at its size, a little smaller when it's long, and past that cut so its domain stays whole
    /// (`HostText`): the subdomains quiet, the domain that says whose site it is in the text's own ink.
    static func fitted(_ name: String, in width: CGFloat) -> NSAttributedString {
        let fit = HostText.fit(name, width: width, size: 20, shrink: 5, smallest: 13) { text, size in
            ceil(Tokens.Font.voiceText(text, size: size).size().width)
        }
        return HostText.styled(fit, font: { Tokens.Font.voice($0) }, kern: { Tokens.Font.voiceKern($0) })
    }

    fileprivate func layoutContent(dryRun: Bool) -> CGFloat {
        func place(_ view: NSView, _ rect: NSRect) { if !dryRun { view.frame = rect } }
        // The certificate is a page of its own, laid out by itself.
        if page == .connection, let certificate = certificatePage {
            let h = certificate.height(for: width, pad: pad)
            place(certificate, NSRect(x: 0, y: 0, width: width, height: h))
            return headerBand + h
        }
        let inner = width - pad * 2
        // A page under its header starts at the top of the sheet; the first page, a padding down.
        var y = page == .main ? pad : 0
        // The room after the last thing placed, and the room under its words inside it: both are taken back at the
        // end, so the panel's bottom margin counts from the words, as its top does.
        var gapAfter: CGFloat = 0, slack: CGFloat = 0
        func end(_ gap: CGFloat, slack s: CGFloat = 0) { y += gap; gapAfter = gap; slack = s }
        func link(_ row: PanelLinkRow) {
            place(row, NSRect(x: pad - PanelLinkRow.outset, y: y, width: inner + PanelLinkRow.outset * 2, height: PanelLinkRow.height))
            y += PanelLinkRow.height
        }
        func finish() -> CGFloat { headerBand + y - gapAfter - slack + pad }
        // A page's box covers the panel, so what's in it is placed in the panel's own terms.
        for box in [mainBox, permissionsBox, zapsBox] where !box.isHidden { place(box, NSRect(x: 0, y: 0, width: width, height: 10_000)) }
        func group(_ group: PanelGroup) {
            let height = group.height(for: inner)
            place(group, NSRect(x: pad, y: y, width: inner, height: height))
            y += height
        }

        switch page {
        case .permissions:
            if !permissionsEmpty.isHidden {
                let w = inner + Label.inset * 2
                let h = ceil(permissionsEmpty.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: w, height: 10_000)).height ?? permissionsEmpty.lineHeight)
                // Alone, a step below the header; WebRTC's row follows a step lower.
                place(permissionsEmpty, NSRect(x: pad - Label.inset, y: y + Tokens.Space.x2, width: w, height: h))
                y += Tokens.Space.x2 + h
                if !permissionsGroup.rows.isEmpty { y += Tokens.Space.x3 }
            }
            group(permissionsGroup)
            if !permissionsGroup.rows.isEmpty { end(0, slack: permissionsGroup.bottomSlack) }
            if let resetPermissions, !resetPermissions.isHidden {
                y += Tokens.Space.x2
                link(resetPermissions)
                end(0, slack: resetPermissions.bottomSlack)
            }
            return finish()
        case .zapped:
            group(zapsGroup)
            if !zapsGroup.rows.isEmpty { end(0, slack: zapsGroup.bottomSlack) }
            if let restoreAllRow {
                y += Tokens.Space.x2
                link(restoreAllRow)
                end(0, slack: restoreAllRow.bottomSlack)
            }
            return finish()
        case .main, .connection:
            break
        }

        // Spaced by ink: `pad` to the first and last ink, `blockGap` between blocks, `headingGap` under a heading.
        let blockGap = Tokens.Space.x6, headingGap = Tokens.Space.x3
        var ink = pad, gap: CGFloat = 0
        func top(_ slack: CGFloat) -> CGFloat { ink + gap - slack }
        func ended(_ bottom: CGFloat, next: CGFloat = blockGap) { ink = bottom; gap = next }
        func finishMain() -> CGFloat { ink + pad }
        func heading(_ label: Label) {
            let caps = label.capsSpan
            let y = top(caps.top)
            place(label, NSRect(x: pad - Label.inset, y: y, width: inner + Label.inset * 2, height: label.lineHeight))
            ended(y + caps.bottom, next: headingGap)
        }

        // The extensions, below the actions (#215): folded to a header with their strip, or open as tiles.
        func extensions() {
            guard let section = extensionsSection else { return }
            let h = section.height(for: inner)
            let y = top(section.topSlack)
            place(section, NSRect(x: pad - PanelLinkRow.outset, y: y, width: inner + PanelLinkRow.outset * 2, height: h))
            ended(y + h - section.bottomSlack)
        }
        // A new tab has no site: the panel is your extensions alone.
        if isBlank {
            extensions()
            return finishMain()
        }

        // Header: the site's icon and name, and ⋯.
        let iconSide = Tokens.Space.x6
        let moreSide = Tokens.Metric.iconButton
        // The name, and under it the connection's line when there is one: the icon and ⋯ in the middle of both.
        let lineHeight = connectionLine == nil ? 0 : ConnectionLine.height
        let block = siteName.lineHeight + lineHeight
        let headerHeight = max(block, moreSide)
        let nameOffset = (headerHeight - block) / 2
        let iconOffset = (headerHeight - iconSide) / 2
        let nameCaps = siteName.capsSpan
        let textBottom = connectionLine.map { nameOffset + siteName.lineHeight + $0.inkBottom } ?? nameOffset + nameCaps.bottom
        let headerY = top(min(iconOffset, nameOffset + nameCaps.top))
        let nameY = headerY + nameOffset
        // ⋯'s dots end on the text column's edge, as the switches below do.
        let dots = Tokens.Symbol.inkSize(moreButton.symbol, size: moreButton.symbolSize).width
        let moreX = (width - pad - moreSide / 2 - dots / 2).rounded()
        place(moreButton, NSRect(x: moreX, y: headerY + (headerHeight - moreSide) / 2, width: moreSide, height: moreSide))
        place(icon, NSRect(x: pad, y: headerY + iconOffset, width: iconSide, height: iconSide))
        let textX = pad + iconSide + Tokens.Space.x3
        let textWidth = (moreButton.isHidden ? width - pad : moreX) - textX
        siteName.attributedStringValue = Self.fitted(shownName, in: textWidth)
        siteNameHover.toolTip = siteName.stringValue == shownName ? nil : shownName
        place(siteName, NSRect(x: textX - Label.inset, y: nameY, width: textWidth + Label.inset * 2, height: siteName.lineHeight))
        place(siteNameHover, NSRect(x: textX, y: nameY, width: min(textWidth, siteName.inkWidth), height: siteName.lineHeight))
        if let connectionLine {
            // On the name's text column, as wide as its words: the rest of the header stays the name's.
            place(connectionLine, NSRect(x: textX, y: nameY + siteName.lineHeight, width: min(textWidth, connectionLine.fittingWidth), height: lineHeight))
        }
        ended(headerY + max(iconOffset + iconSide, textBottom))
        // Why it isn't secure, when that isn't plain to see, under the whole header.
        if !connectionNote.isHidden {
            let w = inner + Label.inset * 2
            let h = ceil(connectionNote.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: w, height: 10_000)).height ?? connectionNote.lineHeight)
            let caps = connectionNote.capsSpan
            gap = Tokens.Space.x3
            let y = top(caps.top)
            place(connectionNote, NSRect(x: pad - Label.inset, y: y, width: w, height: h))
            ended(y + h - connectionNote.lineHeight + caps.bottom)
        }

        // Actions are named tiles: one row, like the markings along a device's edge. In a narrow panel, where a name
        // wouldn't show whole, they share even rows instead, never one left alone under the rest.
        func tiles(_ tiles: [PanelTile]) {
            guard let first = tiles.first else { return }
            let layout = Self.actionRows(count: tiles.count, width: inner,
                                         comfortable: tiles.map(\.captionWidth).max() ?? 0,
                                         tightest: tiles.map(\.captionTightWidth).max() ?? 0)
            let slack = first.captionedSlack(in: PanelTile.captionedHeight)
            var y = top(slack.top)
            Self.grid(tiles, columns: layout.first ?? 1, gap: 0, centered: true, height: PanelTile.captionedHeight,
                      x: pad, inner: inner, y: &y, place: place)
            ended(y - slack.bottom)
        }
        tiles(actionTiles)

        // The developer tools of a development page that doesn't have them above it, under their own name, laid out as the actions are.
        if !developerTiles.isEmpty {
            heading(developerLabel)
            tiles(developerTiles)
        }

        extensions()

        // One line into each of the other pages, each saying what's there; only those that apply.
        var c = SitePanelRows.Context()
        // JavaScript gives every web page a Permissions page, whether or not anything else was asked.
        c.hasPermissions = permissionsRow?.isHidden == false || (["http", "https"].contains(url.scheme?.lowercased() ?? "") && permissionsRow != nil)
        c.zapped = zappedRow == nil ? 0 : boost.zaps.count
        c.styled = styleRow != nil && boost.hasStyle
        let links = SitePanelRows.links(c)
        let linkRows: [(SitePanelRows.Link, PanelLinkRow?)] = [(.permissions, permissionsRow), (.zapped, zappedRow), (.style, styleRow)]
        var lastLink: PanelLinkRow?
        for (kind, row) in linkRows {
            guard let row else { continue }
            row.isHidden = !links.contains(kind)
            guard !row.isHidden else { continue }
            // One after another, a list: a row's gap between them.
            if let lastLink { gap = lastLink.bottomSlack + PanelLinkRow.gap + row.topSlack }
            let y = top(row.topSlack)
            place(row, NSRect(x: pad - PanelLinkRow.outset, y: y, width: inner + PanelLinkRow.outset * 2, height: PanelLinkRow.height))
            ended(y + PanelLinkRow.height - row.bottomSlack)
            lastLink = row
        }

        // This site's switches.
        if !rows.isEmpty {
            heading(siteLabel)
            let y = top(self.group.topSlack)
            let height = self.group.height(for: inner)
            place(self.group, NSRect(x: pad, y: y, width: inner, height: height))
            ended(y + height - self.group.bottomSlack)
        }
        return finishMain()
    }

    /// Tiles in rows of `columns`, square unless given a height. A shorter last row sits in the middle under the full
    /// ones (three over two) when `centered`, not hanging to the left.
    private static func grid(_ tiles: [PanelTile], columns: Int, gap: CGFloat, centered: Bool, height: CGFloat?, x: CGFloat, inner: CGFloat,
                             y: inout CGFloat, place: (NSView, NSRect) -> Void) {
        let side = floor((inner - gap * CGFloat(columns - 1)) / CGFloat(columns))
        let h = height ?? side
        let rows = (tiles.count + columns - 1) / columns
        for (i, tile) in tiles.enumerated() {
            let column = i % columns, row = i / columns
            let inRow = row == rows - 1 ? tiles.count - row * columns : columns
            let shift = centered ? CGFloat(columns - inRow) * (side + gap) / 2 : 0
            place(tile, NSRect(x: x + shift + CGFloat(column) * (side + gap), y: y + CGFloat(row) * (h + gap), width: side, height: h))
        }
        y += CGFloat(rows) * (h + gap) - gap
    }

    /// How many actions go on each row, top to bottom: all on one when every name shows whole with room around it,
    /// otherwise the fewest even rows that keep that room. A layout that would leave one action alone under the others
    /// (two, two, one) takes a row more snugly instead (three over two), its names as close as they show whole.
    static func actionRows(count: Int, width: CGFloat, comfortable: CGFloat, tightest: CGFloat) -> [Int] {
        guard count > 0 else { return [] }
        func rows(_ wanted: Int) -> [Int] {
            // As even as the count allows: the same number of rows, the fewest to a row that fill them.
            let rowCount = (count + wanted - 1) / wanted
            let columns = (count + rowCount - 1) / rowCount
            return stride(from: 0, to: count, by: columns).map { min(columns, count - $0) }
        }
        // Never one left under the rest, nor a single file of them down the panel.
        let even = (1...count).reversed().map(rows).filter { $0.count == 1 || $0.last! > 1 }
        for need in [comfortable, tightest] {
            if let fits = even.first(where: { width / CGFloat($0[0]) >= need }) { return fits }
        }
        // Too narrow for any name whole: the widest even tiles, names cut short; the tooltip has the full name.
        return even.last ?? [count]
    }
}

/// The mark on a pinned extension's button in Site Controls: a small round chip with a hairline and a filled pin at a
/// row's end, or the pin alone in a tile's top-right corner (top-left beside an attention dot), clear of the icon. It
/// only shows what's pinned and takes no clicks: the whole tile opens the extension, and pinning is in its menu.
final class PinMark: NSView {
    enum State { case unpinned, pinned, atLimit }

    /// On the panel's own color, so it reads cleanly over the icon under it in dark too.
    private let ground = ColorView(color: Tokens.Color.panelBackground)
    private let chip = ColorView(color: Tokens.Color.controlFill)
    private let icon = NSImageView()
    var state = State.unpinned

    static let symbol = "pin.fill"

    /// Where it goes on a tile, in the tile's superview's terms: the corner square outside the icon centered in it.
    static func frame(on tile: NSRect, iconSide: CGFloat, left: Bool) -> NSRect {
        let side = max(0, (tile.width - iconSide) / 2)
        return NSRect(x: left ? tile.minX : tile.maxX - side, y: tile.minY, width: side, height: side)
    }

    /// On a tile it's the pin alone: there's no icon under it to set it apart from.
    init(onTile: Bool = false) {
        let side = Tokens.Sidebar.pinMark
        super.init(frame: NSRect(x: 0, y: 0, width: side, height: side))
        isHidden = true
        for view in [ground, chip] where !onTile {
            view.frame = bounds
            view.layer?.cornerRadius = side / 2
            view.autoresizingMask = [.width, .height]
            addSubview(view)
        }
        chip.layer?.borderWidth = Tokens.Metric.hairline
        chip.edgeColor = Tokens.Color.controlEdge
        let glyph = Tokens.Sidebar.pinMarkGlyph
        icon.imageScaling = .scaleNone
        icon.image = Tokens.Symbol.image(Self.symbol, size: glyph)
        icon.contentTintColor = Tokens.Color.textSecondary
        // The glyph's ink, not its image, in the chip's middle.
        let ink = Tokens.Symbol.inkOffset(Self.symbol, size: glyph)
        glyphInk = ink
        addSubview(icon)
        setAccessibilityElement(false)
    }

    private var glyphInk = CGSize.zero

    override func layout() {
        super.layout()
        icon.frame = bounds.offsetBy(dx: -glyphInk.width, dy: glyphInk.height)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A square action in the site panel: a glass tile (`GlassTile`) with a symbol (or an extension's icon), an optional
/// caption, and a badge. On (Reader open) is the window's accent at the selection opacity.
final class PanelTile: GlassTile {
    private let iconView = NSImageView()
    private let caption: Label?
    private var badgeView: BadgeView?
    var isOn = false { didSet { stateDidChange(animated: false) } }
    /// An extension that doesn't work on this site: its icon and name faded, still a button (#215).
    var isDimmed = false { didSet { stateDidChange(animated: false) } }
    /// The icon's side, when not the usual (the folded Extensions strip's small icons).
    var iconSide: CGFloat? { didSet { needsLayout = true } }
    var isAttention = false
    var badge = "" {
        didSet {
            badgeView?.removeFromSuperview()
            badgeView = nil
            guard !badge.isEmpty else { return }
            // The same pill as on a pinned button in the address, in the tile's corner; on a tile with a name under
            // its icon (the console's count), at the icon's corner, clear of the name.
            let view = BadgeView(text: badge, attention: isAttention)
            if caption == nil {
                view.inset = Self.badgeInset
                addSubview(view)
            } else {
                view.inset = Self.iconBadgeInset
                iconView.addSubview(view)
            }
            badgeView = view
        }
    }

    /// How wide the tile must be for its name to show whole.
    var captionWidth: CGFloat { caption.map { ceil($0.textWidth) + Tokens.Space.x2 } ?? 0 }
    /// The narrowest the tile can be with its name still whole, without the room around it.
    var captionTightWidth: CGFloat { caption.map { ceil($0.textWidth) } ?? 0 }

    /// A tile with a caption: the icon over its name.
    static let captionedHeight = Tokens.Space.x12 + Tokens.Space.x2

    /// In a captioned tile `height` tall: from its top to the icon, and from its name's baseline to its bottom.
    func captionedSlack(in height: CGFloat) -> (top: CGFloat, bottom: CGFloat) {
        guard let caption else { return (0, 0) }
        let top = (height - (Tokens.Space.x5 + Tokens.Space.x1 + caption.lineHeight)) / 2
        return (top, height - (top + Tokens.Space.x5 + Tokens.Space.x1 + caption.capsSpan.bottom))
    }

    init(image: NSImage? = nil, symbol: String, caption text: String?) {
        caption = text.map { Label($0, font: .systemFont(ofSize: Tokens.TypeSize.small), color: Tokens.Color.textSecondary) }
        super.init(frame: .zero)
        iconView.image = image ?? Tokens.Symbol.image(symbol, size: text == nil ? Tokens.TypeSize.body : Tokens.TypeSize.title)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.contentTintColor = Tokens.Color.icon
        addSubview(iconView)
        if let caption {
            caption.alignment = .center
            caption.lineBreakMode = .byTruncatingTail
            addSubview(caption)
        }
        setAccessibilityRole(.button)
        setAccessibilityLabel(text ?? "")
        stateDidChange(animated: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        // One size for every icon, whatever its artwork, so a row of them reads as a set.
        let side: CGFloat = iconSide ?? (caption == nil ? Tokens.Space.x5 + 2 : Tokens.Space.x5)
        if let caption {
            let total = side + Tokens.Space.x1 + caption.lineHeight
            let top = (bounds.height - total) / 2
            // The icon above its name, whichever way the view counts.
            let iconY = isFlipped ? top : bounds.height - top - side
            let captionY = isFlipped ? top + side + Tokens.Space.x1 : top
            iconView.frame = NSRect(x: (bounds.width - side) / 2, y: iconY, width: side, height: side)
            caption.frame = NSRect(x: 0, y: captionY, width: bounds.width, height: caption.lineHeight)
        } else {
            iconView.frame = NSRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
        }
        badgeView?.needsLayout = true
    }

    /// From the tile's edges to its count: inside its rounded corner.
    static let badgeInset: CGFloat = 3
    /// Over a captioned tile's icon: hanging off its bottom-right corner, as on a Dock icon.
    static let iconBadgeInset: CGFloat = -6

    override func stateDidChange(animated: Bool) {
        let accent = Brand.Theme.for(self).accent
        // No box: a thin line glyph over its small name, like a marking on a device. Only the pointer or a press
        // shows a soft wash behind it.
        let wash: NSColor? = isPressed ? Tokens.Color.pressedFill : isHovered ? Tokens.Color.hoverFill : nil
        layer?.set(backgroundColor: wash.map { cgColor($0) }, animated: false)
        layer?.borderWidth = 0
        setLifted(false)
        let faded = !isEnabled || isDimmed
        iconView.alphaValue = faded ? Tokens.Opacity.disabled : 1
        iconView.contentTintColor = isOn ? accent : Tokens.Color.icon
        caption?.alphaValue = faded ? Tokens.Opacity.disabled : 1
        caption?.textColor = isOn ? Tokens.Color.textPrimary : Tokens.Color.textSecondary
    }
}

/// "This site"'s settings: plain rows on the panel itself, separated by space alone, no card and no lines.
final class PanelGroup: NSView {
    var rows: [PanelRow] = [] {
        didSet {
            oldValue.forEach { $0.removeFromSuperview() }
            rows.forEach { addSubview($0) }
            needsLayout = true
        }
    }

    func height(for width: CGFloat) -> CGFloat { rows.map { $0.height(for: width) }.reduce(0, +) }
    /// The room above the first row's ink and below the last's: the panel spaces by the ink.
    var topSlack: CGFloat { rows.first?.topSlack ?? 0 }
    var bottomSlack: CGFloat { rows.last?.bottomSlack(for: bounds.width) ?? 0 }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        var y: CGFloat = 0
        for row in rows {
            let height = row.height(for: bounds.width)
            row.frame = NSRect(x: 0, y: y, width: bounds.width, height: height)
            y += height
        }
    }
}

/// One line of "This site", as Settings draws its rows: a name, with what it's set to under it for a switch, and a
/// switch, a dropdown or the zoom stepper at the right. No symbols: the names say what each is.
final class PanelRow: NSView {
    static let height = Tokens.Page.groupRowHeight
    private let title: Label
    private let control: NSView
    private let value: Label?
    /// The words' height: the title, and the line under it when there is one.
    var contentHeight: CGFloat { title.lineHeight + (value.flatMap { $0.isHidden ? nil : $0.lineHeight } ?? 0) }
    /// From the row's top to its first ink: the caps of its name, or a control's box.
    var topSlack: CGFloat { min(textInk.top, controlSlack) }
    /// From the row's last ink to its bottom: the baseline of its words, or a control's box.
    var bottomSlack: CGFloat { bottomSlack(for: bounds.width) }
    func bottomSlack(for width: CGFloat) -> CGFloat {
        isStacked(width) ? textTop : min(Self.height - textInk.bottom, controlSlack)
    }

    /// Its height at `width`: one line of the panel, or more with its control under its name.
    func height(for width: CGFloat) -> CGFloat {
        isStacked(width) ? textTop + contentHeight + Tokens.Space.x2 + wantedSize.height + textTop : Self.height
    }

    /// Where its words start, centered in a row's height.
    private var textTop: CGFloat { (Self.height - contentHeight) / 2 }

    private var wantedSize: NSSize { control.fittingSize.width > 0 ? control.fittingSize : control.intrinsicContentSize }

    /// The width its name and the line under it need on one line.
    private var namedWidth: CGFloat { ceil(max(title.textWidth, value.map { $0.isHidden ? 0 : $0.textWidth } ?? 0)) }

    /// A name longer than the room its menu leaves it (a longer language) puts the menu under the name instead.
    /// A short name keeps the menu beside it, squeezed as before, with its choice whole in a tooltip.
    private func isStacked(_ width: CGFloat) -> Bool {
        guard width > 0, control is DropdownButton else { return false }
        return namedWidth > width - sideBySideWidth(width) - Tokens.Space.x2
    }

    /// The control's width beside the name.
    private func sideBySideWidth(_ width: CGFloat) -> CGFloat {
        min(wantedSize.width, max(0, width - min(namedWidth, Self.minimumTitle) - Tokens.Space.x2))
    }

    private var textInk: (top: CGFloat, bottom: CGFloat) {
        guard let value, !value.isHidden else {
            let y = title.centeredY(in: Self.height)
            return (y + title.capsSpan.top, y + title.capsSpan.bottom)
        }
        let top = (Self.height - contentHeight) / 2
        return (top + title.capsSpan.top, top + title.lineHeight + value.capsSpan.bottom)
    }

    /// Above and below a control with a box of its own; the zoom stepper's bare glyphs count as words.
    private var controlSlack: CGFloat {
        guard !(control is ZoomStepper) else { return .greatestFiniteMagnitude }
        let wanted = control.fittingSize.height > 0 ? control.fittingSize.height : control.intrinsicContentSize.height
        return (Self.height - wanted) / 2
    }

    private init(_ title: String, control: NSView, value: String? = nil) {
        self.title = Label(title, font: Tokens.Font.body(), color: Tokens.Color.textPrimary)
        self.control = control
        // What was chosen sits under the name, so neither is cut short beside the button.
        self.value = value.map { Label($0, font: Tokens.Font.small(), color: Tokens.Color.textSecondary) }
        super.init(frame: .zero)
        [self.title, control].forEach { addSubview($0) }
        if let label = self.value { addSubview(label) }
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    /// A short name, a switch, and under the name what the switch means right now ("Allowed on this site").
    static func toggle(_ title: String, on: Bool, status: @escaping (Bool) -> String, changed: @escaping (Bool) -> Void) -> PanelRow {
        toggle(title, status: status, on: on, changed: changed)
    }

    static func toggle(_ title: String, status: @escaping (Bool) -> String, on: Bool, changed: @escaping (Bool) -> Void) -> PanelRow {
        let toggle = Toggle(isOn: on)
        toggle.setAccessibilityLabel(title)
        let row = PanelRow(title, control: toggle, value: status(on))
        toggle.onChange = { [weak row] on in
            row?.value?.stringValue = status(on)
            changed(on)
        }
        return row
    }

    /// A switch compatibility mode holds off (#497): dimmed, and saying so under its name.
    static func overridden(_ title: String) -> PanelRow {
        let toggle = Toggle(isOn: false)
        toggle.isEnabled = false
        toggle.setAccessibilityLabel(title)
        let row = PanelRow(title, control: toggle, value: SitePanel.offInCompatibility)
        row.title.textColor = Tokens.Color.textDisabled
        return row
    }

    /// A name and a dropdown of choices: a permission's Ask, Allow or Block. With `status`, what the choice means
    /// right now sits under the name, read again once a choice has been made (Dark page's "On, following Settings").
    static func choice(_ title: String, options: [String], selected: Int, actions: [DropdownButton.Action] = [], status: ((Int) -> String?)? = nil,
                       chose: @escaping (Int) -> Void) -> PanelRow {
        let dropdown = DropdownButton()
        dropdown.options = options.map { DropdownButton.Option(title: $0) }
        dropdown.actions = actions
        dropdown.selectedIndex = selected
        dropdown.setAccessibilityLabel(title)
        let row = PanelRow(title, control: dropdown, value: status.map { $0(selected) ?? "" })
        row.value?.isHidden = row.value?.stringValue.isEmpty ?? true
        dropdown.onSelect = { [weak row] index in
            chose(index)
            guard let row, let status, let value = row.value else { return }
            value.stringValue = status(index) ?? ""
            value.isHidden = value.stringValue.isEmpty
            row.needsLayout = true
        }
        return row
    }

    /// A name and a control of the panel's own (the zoom stepper).
    static func custom(_ title: String, control: NSView) -> PanelRow { PanelRow(title, control: control) }

    /// A zapped element: its short name, its selector under it in code type cut in the middle (whole on hover and to
    /// VoiceOver), and × to show it again.
    static func zap(_ selector: String, name: String? = nil, remove: @escaping () -> Void) -> PanelRow {
        let name = name ?? SiteBoosts.label(forZap: selector)
        let button = IconButton(symbol: "xmark", size: .compact, toolTip: SiteBoosts.restoreTitle)
        button.setAccessibilityLabel(SiteBoosts.restoreLabel(name))
        button.onClick = { _ in remove() }
        let row = PanelRow(name, control: button, value: selector)
        row.value?.font = Tokens.Font.code(Tokens.TypeSize.small)
        row.value?.lineBreakMode = .byTruncatingMiddle
        // A selector that is its own name ("div.banner") says it once.
        row.value?.isHidden = name == selector
        row.toolTip = selector
        row.setAccessibilityElement(true)
        row.setAccessibilityRole(.group)
        row.setAccessibilityLabel(name)
        row.setAccessibilityValue(selector)
        return row
    }

    #if DEBUG
    /// Its name, and what its dropdown or switch is set to.
    var debugTitle: String {
        if let dropdown = control as? DropdownButton {
            return "\(title.stringValue): \(dropdown.accessibilityValue() as? String ?? "")" + (value.flatMap { $0.isHidden ? nil : " (\($0.stringValue))" } ?? "")
        }
        if let toggle = control as? Toggle { return "\(title.stringValue): \(toggle.isOn ? "on" : "off")" + (toggle.isEnabled ? "" : ", dimmed") }
        return title.stringValue
    }

    /// Width needed for the title, subtitle and control without wrapping.
    var debugWants: CGFloat {
        let wanted = control.fittingSize.width > 0 ? control.fittingSize : control.intrinsicContentSize
        return ceil(max(title.textWidth, value.map { $0.isHidden ? 0 : $0.textWidth } ?? 0)) + Tokens.Space.x2 + wanted.width
    }

    var debugDropdown: DropdownButton? { control as? DropdownButton }

    /// choose <index>: picks that choice in the row's dropdown, as its menu would.
    func debugChoose(_ index: Int) {
        // A switch: 1 is on, 0 off.
        if let toggle = control as? Toggle {
            toggle.isOn = index != 0
            toggle.onChange?(toggle.isOn)
            return
        }
        guard let dropdown = control as? DropdownButton, dropdown.options.indices.contains(index) else { return }
        dropdown.selectedIndex = index
        dropdown.onSelect?(index)
    }
    #endif

    /// Minimum width a row title keeps beside its control, enough for "Microphone" or "JavaScript". A control wanting
    /// more (a menu of long space names) takes the rest, shows its full value in a tooltip, and its menu opens as wide
    /// as needed (#314).
    private static let minimumTitle: CGFloat = 96

    override func layout() {
        super.layout()
        // Not placed yet: a control sized by its frame (an icon button) would be squeezed to nothing for good.
        guard bounds.width > 0 else { return }
        let wanted = wantedSize
        let x = -Label.inset
        if isStacked(bounds.width) {
            title.usesSingleLineMode = true
            title.maximumNumberOfLines = 1
            title.lineBreakMode = .byTruncatingTail
            title.cell?.wraps = false
            title.frame = NSRect(x: x, y: textTop, width: bounds.width + Label.inset * 2, height: title.lineHeight)
            if let value, !value.isHidden {
                value.frame = NSRect(x: x, y: title.frame.maxY, width: bounds.width + Label.inset * 2, height: value.lineHeight)
            }
            control.frame = NSRect(x: 0, y: textTop + contentHeight + Tokens.Space.x2, width: min(wanted.width, bounds.width), height: wanted.height)
            return
        }
        // Shorter titles keep only their own width, so they never squeeze the control.
        let size = NSSize(width: sideBySideWidth(bounds.width), height: wanted.height)
        control.frame = NSRect(x: bounds.width - size.width, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
        let right = control.frame.minX - Tokens.Space.x2 - x
        guard let value, !value.isHidden else {
            // A long title beside its control wraps to a second line instead of truncating; the row fits two.
            let twoLines = title.textWidth > right
            title.usesSingleLineMode = !twoLines
            title.maximumNumberOfLines = twoLines ? 2 : 1
            title.lineBreakMode = twoLines ? .byWordWrapping : .byTruncatingTail
            title.cell?.wraps = twoLines
            let h = twoLines ? min(ceil(title.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: right, height: 200)).height ?? title.lineHeight), bounds.height) : title.lineHeight
            title.frame = NSRect(x: x, y: twoLines ? (bounds.height - h) / 2 : title.centeredY(in: bounds.height), width: right, height: h)
            return
        }
        let top = (bounds.height - title.lineHeight - value.lineHeight) / 2
        title.frame = NSRect(x: x, y: top, width: right, height: title.lineHeight)
        value.frame = NSRect(x: x, y: title.frame.maxY, width: right, height: value.lineHeight)
    }
}

/// A row that is the control: its name, and a chevron when it goes somewhere (Settings › Extensions). The hover wash
/// reaches `PanelLinkRow.outset` past the text on each side, so its words stand on the panel's text column.
final class PanelLinkRow: InteractiveView {
    static let height = Tokens.Page.rowHeight
    static let outset = Tokens.Space.x2
    /// Between two rows in a list, the sidebar's gap: a hovered row's fill never touches its neighbor's.
    static let gap = Tokens.Sidebar.rowGap
    private let title: Label
    /// What's there, quiet at the trailing end, before the chevron: "Secure", "2 allowed".
    private let valueLabel = Label("", font: Tokens.Font.body(), color: Tokens.Color.textTertiary)
    private let chevron = NSImageView()
    private let run: () -> Void
    /// The room above the caps of its name and below their baseline: the panel spaces by the ink.
    var topSlack: CGFloat { title.centeredY(in: Self.height) + title.capsSpan.top }
    var bottomSlack: CGFloat { Self.height - title.centeredY(in: Self.height) - title.capsSpan.bottom }
    private var fullText = ""
    var value: String {
        get { fullText }
        set { fullText = newValue; valueLabel.stringValue = newValue; setAccessibilityValue(newValue); needsLayout = true }
    }
    /// What the value says where the whole of it doesn't fit ("2 set" for "1 allowed, 1 blocked").
    var shortValue: String? { didSet { needsLayout = true } }

    private func fullValue(fits room: CGFloat) -> Bool {
        ceil((fullText as NSString).size(withAttributes: [.font: valueLabel.font ?? Tokens.Font.body()]).width) + Tokens.Space.x2 <= room
    }
    /// The value's ink, when it warns ("Not secure").
    var valueColor: NSColor? { didSet { valueLabel.textColor = valueColor ?? Tokens.Color.textTertiary } }

    init(_ text: String, value: String = "", goes: Bool = false, run: @escaping () -> Void) {
        title = Label(text, font: Tokens.Font.body(), color: Tokens.Color.textPrimary)
        self.run = run
        super.init(frame: .zero)
        pressScales = true
        layer?.cornerRadius = Tokens.Radius.row
        layer?.cornerCurve = .continuous
        chevron.image = Tokens.Symbol.image("chevron.right", size: Tokens.Symbol.inline)
        chevron.imageScaling = .scaleNone
        chevron.isHidden = !goes
        valueLabel.alignment = .right
        [title, valueLabel, chevron].forEach { addSubview($0) }
        onClick = { [weak self] _ in self?.run() }
        setAccessibilityRole(.button)
        setAccessibilityLabel(text)
        self.value = value
        stateDidChange(animated: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    var debugTitle: String { value.isEmpty ? title.stringValue : "\(title.stringValue): \(value)" }
    /// Width needed for the name and value, including the hover outsets.
    var debugWants: CGFloat {
        let valueWidth = value.isEmpty ? 0 : ceil((value as NSString).size(withAttributes: [.font: valueLabel.font ?? Tokens.Font.body()]).width) + Tokens.Space.x2
        return ceil(title.textWidth) + valueWidth + (chevron.isHidden ? 0 : Tokens.Space.x4 + Tokens.Space.x1)
    }

    /// Its name, for a row that says something else after a click (Show All, Show Less).
    var titleText: String {
        get { title.stringValue }
        set { title.stringValue = newValue; setAccessibilityLabel(newValue); needsLayout = true }
    }

    override func layout() {
        super.layout()
        let side = Tokens.Space.x4
        // The chevron's ink ends on the text column's edge, where the switches and dropdowns end.
        let ink = Tokens.Symbol.inkOffset("chevron.right", size: Tokens.Symbol.inline).width + Tokens.Symbol.inkSize("chevron.right", size: Tokens.Symbol.inline).width / 2
        chevron.frame = NSRect(x: (bounds.width - Self.outset - side / 2 - ink).rounded(), y: (bounds.height - side) / 2, width: side, height: side)
        let right = chevron.isHidden ? bounds.width - Self.outset : chevron.frame.minX - Tokens.Space.x1
        // The name whole, the value in the room left; a value too long for it says it the short way.
        let room = right - Self.outset - title.textWidth - Tokens.Space.x2
        if let shortValue, !value.isEmpty {
            valueLabel.stringValue = fullValue(fits: room) ? value : shortValue
        }
        let valueWidth = value.isEmpty ? 0 : max(0, min(valueLabel.textWidth, max(room, (right - Self.outset) / 3)))
        valueLabel.frame = NSRect(x: right - valueWidth + Label.inset, y: valueLabel.centeredY(in: bounds.height), width: valueWidth, height: valueLabel.lineHeight)
        let titleRight = value.isEmpty ? right : right - valueWidth - Tokens.Space.x1
        title.frame = NSRect(x: Self.outset - Label.inset, y: title.centeredY(in: bounds.height),
                             width: titleRight - Self.outset + Label.inset * 2, height: title.lineHeight)
    }

    override func stateDidChange(animated: Bool) {
        // A row that goes nowhere (Connection on a plain http page) only says what it says: no wash.
        if isEnabled { applyRowStyle(animated: animated) } else { layer?.backgroundColor = nil }
        chevron.contentTintColor = Tokens.Color.textTertiary
    }
}

/// − 100% +: a value a step out or in, and the percentage, which sets it back. The page's zoom in the site panel,
/// and the sidebar's size in Settings › Appearance with steps and words of its own (#361).
final class ZoomStepper: NSView, NSTextFieldDelegate {
    /// The steps it goes through, in values where 1 is 100%: the page's zoom unless a caller sets its own.
    var steps: [CGFloat] = ZoomLevels.steps {
        didSet { invalidateIntrinsicContentSize(); refresh() }
    }
    /// Where the percentage puts it back: a page's default zoom unless a caller sets its own.
    var reset: () -> CGFloat = { ZoomLevels.defaultZoom }
    /// What its buttons say to the pointer and VoiceOver.
    var lessTip = String(localized: "Zoom Out", comment: "Tooltip of the − button on the Zoom row of the site panel.") { didSet { refresh() } }
    var moreTip = String(localized: "Zoom In", comment: "Tooltip of the + button on the Zoom row of the site panel.") { didSet { refresh() } }
    var resetTip = String(localized: "Actual Size", comment: "Tooltip of the percentage on the Zoom row of the site panel: sets the page back to 100%.") { didSet { refresh() } }
    /// After the reset tip: how to type a zoom instead of stepping to it (#395). Nil where typing says nothing
    /// useful, as on the Sidebar size row.
    var typingTip: String? = String(localized: "⇧-click to type a zoom", comment: "After Actual Size in the percentage's tooltip on the Zoom row: Shift-clicking it lets you type a zoom.") { didSet { refresh() } }
    /// The percentage's VoiceOver name, a format with the value in it: "Zoom %@, Actual Size" for a page.
    var percentName = String(localized: "Zoom %@, Actual Size", comment: "VoiceOver name of the percentage on the Zoom row of the site panel: the zoom now, then what pressing it does.") {
        didSet { refresh() }
    }
    private let minus = IconButton(symbol: "minus", size: .compact)
    private let plus = IconButton(symbol: "plus", size: .compact)
    private let percent = PillButton(title: "100%", style: .quiet)
    /// Where a typed percentage goes, over the button while you type (Shift-click, #395).
    private let typedField = PlainTextField(font: Tokens.Font.control(), placeholder: "100%")
    /// How long a hold waits before the second step, then the gap between steps.
    private static let holdDelay: TimeInterval = 0.4
    private static let holdGap: TimeInterval = 0.12
    /// The zoom now, as the page has it.
    var zoom: CGFloat = 1 { didSet { refresh() } }
    var onChange: ((CGFloat) -> Void)?

    /// Wide enough for the widest step ("300%"), so the buttons around it never move.
    private var percentWidth: CGFloat {
        let widest = ZoomLevels.percent(steps.max() ?? 1)
        return ceil((widest as NSString).size(withAttributes: [.font: Tokens.Font.control()]).width) + Tokens.Space.x4
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        [minus, percent, plus].forEach { addSubview($0) }
        minus.onClick = { [weak self] _ in self?.go(-1) }
        plus.onClick = { [weak self] _ in self?.go(1) }
        percent.onClick = { [weak self] event in
            guard let self else { return }
            // Shift-click asks for a percentage instead of resetting (#395).
            if event.modifierFlags.contains(.shift) { self.beginTyping(); return }
            self.set(self.reset())
        }
        typedField.isHidden = true
        typedField.alignment = .center
        typedField.centersText = true
        typedField.delegate = self
        typedField.target = self
        typedField.action = #selector(typedFieldCommitted)
        addSubview(typedField)
        // Held, a button keeps stepping until it lets go (#395).
        for (button, direction) in [(minus, -1), (plus, 1)] as [(IconButton, Int)] {
            // A click steps at once, as a stepper's does, rather than waiting for the release.
            button.clicksOnMouseDown = true
            button.pressChanged = { [weak self] pressed in
                guard let self else { return }
                if pressed { self.startHolding(direction) } else { self.stopHolding() }
            }
        }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Tokens.Metric.compactIconButton * 2 + percentWidth, height: Tokens.Page.controlHeight)
    }
    override var fittingSize: NSSize { intrinsicContentSize }

    #if DEBUG
    func debugPress(_ which: String) {
        switch which {
        case "in": go(1)
        case "out": go(-1)
        default: set(reset())
        }
    }

    func debugType(_ text: String) {
        beginTyping()
        typedField.stringValue = text
        endTyping(commit: true)
    }

    var debugPercentToolTip: String? { percent.toolTip }
    #endif

    private func go(_ direction: Int) {
        guard ZoomLevels.canStep(zoom, by: direction, in: steps) else { return }
        set(ZoomLevels.step(zoom, by: direction, in: steps))
    }

    // MARK: Holding a button (#395)

    private var holdTimer: Timer?
    private var holdingDirection = 0

    /// The press has already stepped once; after a moment's pause it steps again and again until it lets go.
    private func startHolding(_ direction: Int) {
        holdingDirection = direction
        stopHoldingTimer()
        holdTimer = Timer.scheduledTimer(withTimeInterval: Self.holdDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.holdingDirection == direction else { return }
                self.startRepeating(direction)
            }
        }
        // Common mode: the pointer is down, so the run loop isn't in its usual mode, and a timer there never fires.
        RunLoop.main.add(holdTimer!, forMode: .common)
    }

    private func startRepeating(_ direction: Int) {
        stopHoldingTimer()
        // The pause is over: the next step comes at once, then every gap. Waiting a gap here made the first repeat
        // arrive at 0.52s instead of 0.4s.
        guard stepWhileHolding(direction) else { return }
        holdTimer = Timer.scheduledTimer(withTimeInterval: Self.holdGap, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.stepWhileHolding(direction) }
        }
        RunLoop.main.add(holdTimer!, forMode: .common)
    }

    /// One step of a hold, or the end of it at the stepper's end.
    @discardableResult
    private func stepWhileHolding(_ direction: Int) -> Bool {
        guard ZoomLevels.canStep(zoom, by: direction, in: steps) else { stopHolding(); return false }
        go(direction)
        return true
    }

    private func stopHoldingTimer() {
        holdTimer?.invalidate()
        holdTimer = nil
    }

    private func stopHolding() {
        holdingDirection = 0
        stopHoldingTimer()
    }

    // MARK: Typing a percentage (#395)

    /// Shift-click on the percentage: it becomes a field with the zoom now in it, selected, so a number replaces it.
    private func beginTyping() {
        stopHolding()
        typedField.stringValue = ZoomLevels.percent(zoom)
        typedField.frame = percent.frame
        // A field, not a bolder percentage: the panel's faint fill and hairline edge, in the button's place.
        typedField.wantsLayer = true
        typedField.layer?.cornerRadius = Tokens.Radius.control
        typedField.layer?.cornerCurve = .continuous
        typedField.layer?.backgroundColor = Tokens.Color.chromeFill.cgColor
        typedField.layer?.borderWidth = Tokens.Metric.hairline
        typedField.layer?.borderColor = Tokens.Color.chromeEdge.cgColor
        typedField.isHidden = false
        percent.isHidden = true
        watchClicksOutside()
        window?.makeFirstResponder(typedField)
        typedField.currentEditor()?.selectAll(nil)
    }

    /// Return or a click away keeps what was typed; Esc drops it.
    private func endTyping(commit: Bool) {
        guard !typedField.isHidden else { return }
        let editor = typedField.currentEditor()
        let typed = ZoomLevels.typed(typedField.stringValue)
        typedField.isHidden = true
        percent.isHidden = false
        stopWatchingClicksOutside()
        if commit, let typed, let first = steps.first, let last = steps.last {
            // Any level between the stepper's ends, not just a preset; ⌘+ and − go on from it.
            set(min(max(typed, first), last))
        }
        // The field editor can stay first responder after Return even once the field is hidden, and then typing
        // goes into nothing. Let it go only if it, or its editor, still holds the focus.
        if let window {
            let responder = window.firstResponder
            if responder === typedField || responder === editor || window.fieldEditor(false, for: typedField) === responder {
                window.makeFirstResponder(nil)
            }
        }
    }

    private var outsideClick: Any?

    /// A click anywhere but the field finishes it, as leaving a field does; the click itself still goes where it
    /// was aimed.
    private func watchClicksOutside() {
        stopWatchingClicksOutside()
        outsideClick = TouchPress.addMonitor(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            guard let self, !self.typedField.isHidden else { return event }
            let point = self.typedField.convert(event.locationInWindow, from: nil)
            if !self.typedField.bounds.contains(point) { self.endTyping(commit: true) }
            return event
        }
    }

    private func stopWatchingClicksOutside() {
        if let outsideClick { TouchPress.removeMonitor(outsideClick) }
        outsideClick = nil
    }

    isolated deinit { stopWatchingClicksOutside() }

    func controlTextDidEndEditing(_ obj: Notification) { endTyping(commit: true) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) { endTyping(commit: false); return true }
        // Return is handled here: left to the field, it selects the text again and takes the focus back.
        if selector == #selector(NSResponder.insertNewline(_:)) { endTyping(commit: true); return true }
        return false
    }

    @objc private func typedFieldCommitted() { endTyping(commit: true) }

    private func set(_ value: CGFloat) {
        guard abs(value - zoom) > 0.001 else { return }
        zoom = value
        onChange?(value)
    }

    private func refresh() {
        minus.toolTip = lessTip
        plus.toolTip = moreTip
        percent.toolTip = [resetTip, typingTip].compactMap { $0 }.joined(separator: "\n")
        percent.title = ZoomLevels.percent(zoom)
        percent.setAccessibilityLabel(String(format: percentName, ZoomLevels.percent(zoom)))
        minus.isEnabled = ZoomLevels.canStep(zoom, by: -1, in: steps)
        plus.isEnabled = ZoomLevels.canStep(zoom, by: 1, in: steps)
    }

    override func layout() {
        super.layout()
        let side = Tokens.Metric.compactIconButton
        minus.frame = NSRect(x: 0, y: (bounds.height - side) / 2, width: side, height: side)
        percent.frame = NSRect(x: side, y: 0, width: percentWidth, height: bounds.height)
        typedField.frame = percent.frame
        plus.frame = NSRect(x: side + percentWidth, y: (bounds.height - side) / 2, width: side, height: side)
    }
}

/// Under the site's name at the top of the panel: whether the connection is secure, in a few small words after the
/// address's lock (#221), for the one thing most people need from it at a glance. Quiet when it's secure; in the
/// warning color, with the address's open lock, when it isn't (plain http, a certificate trusted anyway, parts of the
/// page over plain http). On an https page it's the way into the certificate: a chevron after its words, which step
/// up under the pointer as a section header's do.
final class ConnectionLine: InteractiveView {
    /// Its words with a little room above and below, for the pointer.
    static let height = Label("", font: Tokens.Font.small(), color: .clear).lineHeight + Tokens.Space.x1
    private let glyph = NSImageView()
    private let label: Label
    private let chevron = NSImageView()
    private let warns: Bool
    private let opens: Bool

    init(_ text: String, warns: Bool, opens: Bool, run: @escaping () -> Void) {
        label = Label(text, font: Tokens.Font.small(), color: Tokens.Color.textTertiary)
        self.warns = warns
        self.opens = opens
        super.init(frame: .zero)
        glyph.image = Tokens.Symbol.image(warns ? SitePanel.notSecureSymbol : "lock", size: Tokens.Symbol.inline)
        glyph.imageScaling = .scaleNone
        chevron.image = Tokens.Symbol.image("chevron.right", size: Tokens.Symbol.inline)
        chevron.imageScaling = .scaleNone
        chevron.isHidden = !opens
        [glyph, label, chevron].forEach { addSubview($0) }
        isEnabled = opens
        onClick = { _ in run() }
        if opens { toolTip = String(localized: "Show Certificate", comment: "Tooltip of the line under the site's name in the site panel that says whether the connection is secure: opens the site's certificate.") }
        setAccessibilityElement(true)
        setAccessibilityRole(opens ? .button : .staticText)
        setAccessibilityLabel(String(localized: "Connection", comment: "VoiceOver name of the line under the site's name in the site panel that says whether the page's connection is secure. On an https page it opens the site's certificate."))
        setAccessibilityValue(text)
        stateDidChange(animated: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    var debugText: String { label.stringValue + (warns ? " (warns)" : "") + (opens ? " >" : "") }

    private var side: CGFloat { Tokens.Symbol.inline }
    /// Where its last ink ends, from its top: the words' baseline or the lock's foot.
    var inkBottom: CGFloat {
        let lock = Tokens.Symbol.inkSize(warns ? SitePanel.notSecureSymbol : "lock", size: side).height
        return max(label.centeredY(in: Self.height) + label.capsSpan.bottom, (Self.height + lock) / 2)
    }
    /// The lock, the words and the chevron, and no more.
    var fittingWidth: CGFloat { ceil(side + Tokens.Space.x1 + label.inkWidth + (opens ? 2 + side : 0)) }

    override func layout() {
        super.layout()
        glyph.frame = NSRect(x: 0, y: (bounds.height - side) / 2, width: side, height: side)
        let x = side + Tokens.Space.x1
        let room = max(0, bounds.width - x - (opens ? 2 + side : 0))
        let w = min(label.inkWidth, room)
        label.frame = NSRect(x: x - Label.inset, y: label.centeredY(in: bounds.height), width: w + Label.inset * 2, height: label.lineHeight)
        chevron.frame = NSRect(x: x + w + 2, y: (bounds.height - side) / 2, width: side, height: side)
    }

    override func stateDidChange(animated: Bool) {
        // No wash: the words step up under the pointer. Not secure always stands out.
        let hot = isHovered && isEnabled
        let ink = warns ? Tokens.Color.caution : hot ? Tokens.Color.textSecondary : Tokens.Color.textTertiary
        label.textColor = ink
        glyph.contentTintColor = ink
        chevron.contentTintColor = hot ? (warns ? Tokens.Color.caution : Tokens.Color.textSecondary) : Tokens.Color.textTertiary
    }
}

/// The top of one of the panel's pages: a way back, and its title.
final class PanelPageHeader: NSView {
    private let back = IconButton(symbol: "chevron.left", size: .compact, toolTip: String(localized: "Back", comment: "Tooltip of the back button on a page of the site panel."))
    private let label: Label
    var onBack: (() -> Void)?
    var title: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }
    /// The panel on a new tab has nowhere to go back to.
    var showsBack = true { didSet { back.isHidden = !showsBack; needsLayout = true } }
    var height: CGFloat { max(label.lineHeight, Tokens.Metric.compactIconButton) }

    init(_ text: String) {
        label = Label(text, font: Tokens.Font.heading(), color: Tokens.Color.textPrimary)
        super.init(frame: .zero)
        back.onClick = { [weak self] _ in self?.onBack?() }
        [back, label].forEach { addSubview($0) }
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        // Align the back glyph's ink with the text column (the button centers ink narrower than the glyph box), title
        // after it.
        let side = Tokens.Metric.compactIconButton
        let inkWidth = Tokens.Symbol.inkSize("chevron.left", size: Tokens.Symbol.compactGlyph).width
        let ink = (side - inkWidth) / 2
        back.frame = NSRect(x: -ink, y: (bounds.height - side) / 2, width: side, height: side)
        let x = showsBack ? round(inkWidth + Tokens.Space.x3) : 0
        label.frame = NSRect(x: x - Label.inset, y: label.centeredY(in: bounds.height), width: bounds.width - x + Label.inset * 2, height: label.lineHeight)
    }
}

/// How tall Site Controls is, and how much of a page scrolls (#220): never past the window's bottom, a page's header
/// kept at the top, and the rest of the page under it scrolling when it doesn't fit.
enum SitePanelSizing {
    /// The panel's left edge. Under the sidebar address (`alongAddress`) it aligns with the field's edge so nothing
    /// shows past its corner; with the address off screen (sidebar hidden), inset from the window edge by `inset`. With
    /// `width` and `overlayWidth`, a panel past the right edge is pulled in by `inset`.
    static func x(_ x: CGFloat, alongAddress: Bool, inset: CGFloat, width: CGFloat = 0, overlayWidth: CGFloat = .greatestFiniteMagnitude) -> CGFloat {
        let placed = alongAddress && x >= 0 ? x : max(inset, x)
        guard placed + width > overlayWidth else { return placed }
        return max(inset, overlayWidth - inset - width)
    }

    /// The tallest the panel can be from `top` in a window's overlay `overlayHeight` tall: down to the window's bottom
    /// inset, and never so short that a page can't show a few rows.
    static func maxHeight(overlayHeight: CGFloat, top: CGFloat) -> CGFloat {
        max(PanelLinkRow.height * 4, overlayHeight - top - Tokens.Metric.cardInset)
    }

    /// The most a list of zapped elements shows before it scrolls: seven rows and half of the next.
    static var zapListHeight: CGFloat { PanelRow.height * 7.5 + Tokens.Space.x2 + PanelLinkRow.height + Tokens.Space.x4 }

    /// The top a page's header keeps: the panel's padding, the header, and the room under it.
    static func headerBand(pad: CGFloat, header: CGFloat) -> CGFloat { pad + header + Tokens.Space.x3 }

    /// The panel's height for a page whose header keeps `band` at the top and whose body is `body` tall, and the room
    /// under the header: all of the body when it fits, and what's left when it doesn't, which then scrolls.
    static func fit(band: CGFloat, body: CGFloat, maxHeight: CGFloat) -> (height: CGFloat, viewport: CGFloat, scrolls: Bool) {
        let height = min(band + body, maxHeight)
        let viewport = max(0, height - band)
        return (height, viewport, body > viewport)
    }
}

/// Which of the panel's rows apply to the page: none is shown that does nothing there.
enum SitePanelRows {
    /// This Site's switches, on the panel's first page.
    enum Row: Equatable { case zoom, adBlocking, cookieBanners, compatibility, darkPage, keepAwake, keepCookies, userAgent, fullScreenFills, alwaysTranslate, localApps, openIn }
    /// Rows linking to subpages. Permissions, JavaScript and extensions share one (#311, #313); the connection is a
    /// line under the site name (#221).
    enum Link: Equatable { case permissions, zapped, style }

    struct Context {
        /// An http or https page, not an extension's own page.
        var isWeb = true
        var isPrivate = false
        /// Ad blocking is on in Settings.
        var adBlocking = true
        /// A cookie consent pop-up was found on the page, or a choice is kept for the site (#175).
        var cookieBanners = false
        /// Choices kept for a site (dark page, keeping tabs awake) are offered for it (`KeepAwake.isOffered`).
        var siteChoices = true
        /// Settings › Privacy › Clear cookies when Zigzag quits is on for the profile: Keep cookies is everyday then (#383).
        var clearsCookiesOnQuit = false
        /// Full screen in the page is offered here, and the page has a video or a choice was made.
        var fullScreen = false
        /// The page is in a language other than yours.
        var foreignLanguage = false
        /// Reader or a PDF covers the page: the page's zoom isn't what you see.
        var coveredPage = false
        /// The site asked for something, or has an answer kept.
        var hasPermissions = false
        /// More than one space to route the site to (#286).
        var manySpaces = false
        /// Number of zapped elements.
        var zapped = 0
        /// The site has custom CSS.
        var styled = false
        /// The master setting for reaching apps on this Mac is on, so this site can be switched on for it.
        var localApps = false
        /// A user agent can be chosen: not on addons.mozilla.org, which is always asked for as Firefox.
        var userAgent = true
    }

    static func rows(_ c: Context) -> [Row] {
        var rows: [Row] = []
        if c.isWeb, !c.coveredPage { rows.append(.zoom) }
        if c.isWeb, c.adBlocking, !c.isPrivate { rows.append(.adBlocking) }
        if c.isWeb, c.cookieBanners, !c.isPrivate { rows.append(.cookieBanners) }
        // Kept for the site: private windows follow it, as they do allowing ads.
        if c.isWeb, !c.isPrivate { rows.append(.compatibility) }
        if c.siteChoices {
            rows.append(.darkPage)
            rows.append(.keepAwake)
            if c.clearsCookiesOnQuit { rows.append(.keepCookies) }
            if c.isWeb, c.userAgent { rows.append(.userAgent) }
        }
        if c.fullScreen { rows.append(.fullScreenFills) }
        if c.foreignLanguage { rows.append(.alwaysTranslate) }
        // Only while Settings allows websites to reach apps on this Mac: before that there is nothing the switch could
        // do, and the place to turn it on is named there.
        if c.localApps { rows.append(.localApps) }
        // Open in: never from a private window, which saves nothing per site.
        if c.isWeb, !c.isPrivate, c.manySpaces { rows.append(.openIn) }
        return rows
    }

    static func links(_ c: Context) -> [Link] {
        var links: [Link] = []
        if c.hasPermissions { links.append(.permissions) }
        if c.zapped > 0 { links.append(.zapped) }
        if c.styled { links.append(.style) }
        return links
    }
}

extension TabManager {
    /// The page Site Controls opens for. From a split pane's strip, that pane's page, made the one you're in first as
    /// a click in it does, so everything the panel does (Reader, translating, a reload) lands on it; otherwise the tab
    /// you're in, which in a split is the pane you're in, never the group's first (#160).
    @discardableResult func siteControlsTab(from pane: Tab? = nil) -> Tab? {
        if let pane, !pane.isClosed, pane !== selectedTab { select(pane) }
        return selectedTab
    }
}
