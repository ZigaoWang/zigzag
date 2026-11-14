import AppKit
import WebKit

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

    private weak var controller: BrowserWindowController?
    /// Opened in Zigzag Mini (#225): its one page, with what a page's own settings are; what needs a browser window
    /// (Reader, translating, extensions' popups, the developer tools) stays there.
    private weak var mini: MiniWindowController?
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
    /// Whether this panel describes the page in this tab.
    func describes(_ other: Tab?) -> Bool { other === tab || other == nil && isBlank }
    /// Opened from a split pane's strip, under its address: it belongs to where that strip is.
    private(set) var isFromPane = false

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
    private let permissionsGroup = PanelGroup()
    private var resetPermissions: PanelLinkRow?
    private let permissionsHeader = PanelPageHeader(String(localized: "Permissions", comment: "Row in the site panel, and the title of its page: the site's camera, location, notifications and pop-ups."))
    /// The certificate, its own page while it's open.
    private var certificatePage: CertificatePage?
    private let certificateHeader = PanelPageHeader(CertificatePage.title)
    /// A hairline under a page's header while the page has scrolled under it, as a built-in page's header has.
    private let headerEdge = ColorView(color: Tokens.Color.separator)
    private var zoomStepper: ZoomStepper?

    /// The panel's pages: the site at a glance, and one each for what's behind its rows.
    enum Page: String { case main, connection, permissions }
    private(set) var page = Page.main
    var showsSubpage: Bool { page != .main }
    private let mainBox = FlippedView()
    private let permissionsBox = FlippedView()

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
    /// `hasCertificate`: the page came with one; Zigzag's own warning in place of a page that didn't load has none,
    /// and is never called secure.
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
    static let pinTitle = String(localized: "Pin to Address", comment: "Item in an extension's menu, tooltip of the pin on its tile in the site panel, and VoiceOver action: gives the extension a button in the address bar.")
    static let unpinTitle = String(localized: "Unpin from Address", comment: "Item in an extension's menu, tooltip of the pin on its tile in the site panel, and VoiceOver action: takes the extension's button out of the address bar.")
    static var pinLimitTip: String { String(localized: "At most \(ExtensionPins.limit) pins. Unpin one first.", comment: "Tooltip of the pin on an extension's tile, and of the disabled menu item, when the most extensions that can be pinned already are. The number is that limit.") }
    static let minimumWidth: CGFloat = 256
    private var width: CGFloat = SitePanel.width
    private var pad: CGFloat { width < Self.width ? Tokens.Space.x3 : Tokens.Space.x4 }

    private init?(controller: BrowserWindowController?, mini: MiniWindowController? = nil, tab asked: Tab?) {
        // With no page (a new tab), it still opens: your extensions are always one click away.
        guard let tab = asked ?? controller.map({ $0.tabManager.selectedTab ?? Tab(url: nil, spaceID: $0.tabManager.currentSpaceID) }) else { return nil }
        let url = tab.url.flatMap { ["http", "https", "webkit-extension"].contains($0.scheme ?? "") ? $0 : nil }
        isBlank = url == nil
        self.controller = controller
        self.mini = mini
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
        [permissionsHeader, certificateHeader, headerEdge].forEach { addSubview($0) }
        [mainBox, permissionsBox].forEach { content.addSubview($0) }
        contentReady = true
        permissionsHeader.onBack = { [weak self] in self?.show(.main) }
        certificateHeader.onBack = { [weak self] in self?.show(.main) }
        scroll.contentView.postsBoundsChangedNotifications = true
        scrollToken = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshHeaderEdge() }
        }
        radius = Tokens.Radius.panel
        icon.image = tab.favicon
        // In the app's voice, as a page names itself; a site's name keeps its own spelling. Plain http or a port of
        // its own is named in full, as its answers are its own: localhost:3000 never reads like localhost:3001.
        let web = ["http", "https"].contains(url?.scheme?.lowercased() ?? "")
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
                                             hasCertificate: tab.webView.map { $0.serverTrust != nil } ?? true)
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
            guard change == .url, let self, let now = tab?.url else { return }
            if (ContentBlocker.site(of: now) ?? now.host() ?? now.absoluteString) != shownSite || SiteOrigin.of(now) != origin { self.close() }
        }
        moreButton.onClick = { [weak self] _ in self?.showMoreMenu() }
        moreButton.isHidden = !canClear
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
        // From the address bar in the sidebar: its width and left edge, just below it. With the sidebar slid out or
        // hidden it's the same width (the address keeps its width off screen), so it never grows past the sidebar.
        // From the address above the page, the sidebar's width, under the address's end where its button is.
        // From a split pane's strip (on its card or up in the bar), its own width, under that pane's address's end,
        // where its button is, and kept in the window.
        let pane = Self.paneStrip(of: anchor) != nil
        let aboveThePage = anchor.isDescendant(of: controller.root.topBar)
        let sidebarLane = controller.root.sidebarWidth - Tokens.Metric.sidebarPadding * 2
        let inset = Tokens.Metric.cardInset
        if pane {
            panel.width = max(Self.minimumWidth, min(Self.width, overlay.bounds.width - inset * 2))
        } else {
            panel.width = anchorFrame.width > 0 && !aboveThePage ? anchorFrame.width : sidebarLane
        }
        if controller.root.sidebarVisible, !controller.root.isSidebarFloatingVisible, !aboveThePage, !pane {
            // The same glass panel as Downloads over the sidebar's lane, with the tabs under it faded back.
            panel.recedes = [controller.sidebar.list]
        }
        var x = aboveThePage || pane ? anchorFrame.maxX - panel.width : anchorFrame.minX
        if pane { x = min(x, overlay.bounds.width - inset - panel.width) }
        panel.frame.origin = NSPoint(x: max(inset, x), y: anchorFrame.maxY + 4)
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
        panel.monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak panel] event in
            guard let panel else { return event }
            return panel.handle(event)
        }
    }

    /// Opens the panel for Zigzag Mini's page under its strip's Site Controls button, or closes the one open (#225).
    static func toggle(in mini: MiniWindowController, from button: IconButton) {
        if let current, current.superview != nil {
            let here = current.window === mini.window
            current.close()
            if here { return }
        }
        guard let panel = SitePanel(controller: nil, mini: mini, tab: mini.tab) else { return }
        panel.anchor = button
        // Over the page, under the button's end, as from the address above a browser window's page; kept in the window.
        let overlay = mini.overlay
        let inset = Tokens.Metric.cardInset
        panel.width = max(Self.minimumWidth, min(Self.width, overlay.bounds.width - inset * 2))
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
        panel.monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak panel] event in
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
        if let scrollToken { NotificationCenter.default.removeObserver(scrollToken) }
        scrollToken = nil
        extensionsToken = nil
        opener?.isSelected = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if Self.current === self { Self.current = nil }
        dismiss()
    }

    // MARK: Content

    /// What this page can do right now, as named tiles: sharing, the link, a screenshot and translating always, Reader
    /// and Picture in Picture when the page has them. The steady ones come first, so they never move.
    private func buildTiles() {
        // Zigzag Mini (`mini`) has the page's own actions: sharing, the link and Picture in Picture.
        guard controller != nil || mini != nil else { return }
        let readerOn = controller?.isShowingReader ?? false
        // (symbol, caption, full name for the tooltip and VoiceOver, on, action)
        var specs: [(String, String, String, Bool, () -> Void)] = []
        let share = String(localized: "Share", comment: "Action in the site panel: shares the page.")
        specs.append(("square.and.arrow.up", share, share, false, { [weak self] in
            guard let self else { return }
            let opener = self.opener, url = self.url
            self.close()
            if let controller = self.controller { controller.sharePage(nil); return }
            guard let opener else { return }
            NSSharingServicePicker(items: [url as NSURL]).show(relativeTo: opener.bounds, of: opener, preferredEdge: .minY)
        }))
        let copyLink = String(localized: "Copy Link", comment: "Action in the site panel: copies the page's address.")
        specs.append(("link", copyLink, copyLink, false, { [weak self] in
            guard let self else { return }
            if let controller = self.controller { controller.copyLink(self.url) } else { self.mini?.copyPageURL(nil) }
            self.close()
        }))
        if controller != nil, PageScreenshot.canTake(tab), !readerOn {
            specs.append(("camera.viewfinder",
                          String(localized: "Capture", comment: "Action in the site panel, under its icon: takes a screenshot of the whole page."),
                          String(localized: "Take Screenshot of Whole Page", comment: "Tooltip of the Capture action in the site panel."),
                          false, { [weak self] in
                guard let self, let controller = self.controller else { return }
                self.close()
                PageScreenshot.take(self.tab, in: controller)
            }))
        }
        // Always here, as in the menu, for when the offer went by or never came: a page that's already in your
        // language says so, and a translated one goes back to its original.
        let translate = String(localized: "Translate", comment: "Action in the site panel: translates the page.")
        if controller != nil { specs.append(("translate",
                      tab.isTranslated ? String(localized: "Original", comment: "Action in the site panel, under its icon: shows the translated page as it was.") : translate,
                      tab.isTranslated ? String(localized: "Show Original", comment: "Tooltip of the Original action in the site panel.") : translate,
                      tab.isTranslated, { [weak self] in self?.controller?.translatePage(); self?.close() })) }
        if controller != nil, tab.isArticle || readerOn {
            specs.append(("doc.plaintext", String(localized: "Reader", comment: "Action in the site panel, under its icon: opens or closes Reader."),
                          readerOn ? String(localized: "Hide Reader", comment: "Tooltip of the Reader action in the site panel, while Reader is on.")
                                   : String(localized: "Show Reader", comment: "Tooltip of the Reader action in the site panel."),
                          readerOn, { [weak self] in self?.controller?.toggleReader(); self?.close() }))
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
            }))
        }
        actionTiles = specs.map { symbol, caption, title, on, run in
            // The panel's own short action words; the tooltip and VoiceOver keep the full name.
            let tile = PanelTile(symbol: symbol, caption: caption)
            tile.toolTip = title
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

    /// Clearing this site's cache or cookies: there when you need it, out of the way when you don't.
    private func showMoreMenu() {
        guard canClear else { return }
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
        let shown: [NSView?] = [mainBox, permissionsBox, certificatePage, pinnedHeader]
        for view in shown.compactMap({ $0 }) where !view.isHidden && view.superview != nil {
            Tokens.Motion.present(view, from: .inPlace, entering: true)
        }
    }

    /// Only the page's own views show.
    private func applyPage() {
        mainBox.isHidden = page != .main
        permissionsBox.isHidden = page != .permissions
        permissionsHeader.isHidden = page != .permissions
        certificateHeader.isHidden = page != .connection
        refreshHeaderEdge()
    }

    /// The page's header, which stays put at the top while the page under it scrolls: none on the first page, which
    /// scrolls whole.
    private var pinnedHeader: PanelPageHeader? {
        switch page {
        case .main: nil
        case .permissions: permissionsHeader
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
        width = max(Self.minimumWidth, min(Self.width, superview.bounds.width - inset * 2))
        frame.origin.x = max(inset, min(frame.minX, superview.bounds.width - inset - width))
        frame.size.width = width
        maxHeight = SitePanelSizing.maxHeight(overlayHeight: superview.bounds.height, top: frame.minY)
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
        return SitePanelSizing.fit(band: band, body: layoutContent(dryRun: true) - band, maxHeight: maxHeight).height
    }

    /// The site at a glance goes in its own page; the other pages add theirs where they're built.
    override func addSubview(_ view: NSView) {
        if contentReady { mainBox.addSubview(view) } else { super.addSubview(view) }
    }

    #if DEBUG
    /// sitepage <main|connection|permissions>: goes to that page, as its row or back button does.
    func debugPage(_ arg: String) {
        guard let next = Page(rawValue: arg) else { return }
        if next == .connection { showCertificate() } else { show(next) }
    }

    /// sitecert <index>: a certificate of the chain chosen on the certificate page, as a click on its row.
    func debugCertificate(_ index: Int) { certificatePage?.debugChoose(index) }

    /// What the panel shows, for checking it without looking: its page, and its rows' names, top to bottom.
    var debugState: [String: Any] {
        ["site": site, "page": page.rawValue, "certificate": certificatePage?.debugState ?? [:],
         "connection": connectionLine?.debugText ?? "",
         "links": [permissionsRow].compactMap { $0 }.filter { !$0.isHidden }.map(\.debugTitle),
         "rows": rows.map(\.debugTitle), "permissions": permissionsGroup.rows.map(\.debugTitle),
         "extensions": extensionsSection?.debugState ?? [:],
         "zoom": zoomStepper.map { ZoomLevels.percent($0.zoom) } ?? "",
         "scroll": ["panel": frame.height, "viewport": scroll.frame.height, "body": content.frame.height, "offset": scroll.contentView.bounds.minY]]
    }

    /// sitedark <automatic|on|off|force>: chooses in the Dark page row's dropdown.
    func debugDark(_ arg: String) {
        guard let index = DarkPages.SiteChoice.allCases.firstIndex(where: { $0.rawValue == arg }) else { return }
        darkRow?.debugChoose(index)
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
        guard f.count == 2, let row = Int(f[0]), permissionsGroup.rows.indices.contains(row),
              let choice = ["ask", "allow", "block"].firstIndex(of: f[1]) else { return }
        permissionsGroup.rows[row].debugChoose(choice)
    }
    #endif

    #if DEBUG
    /// sitextcount <n>: the extensions shown again over and over until there are n, for a look at many without
    /// installing them all; 0 shows them as they are. The copies only show.
    static var debugExtensionCount = 0
    #endif

    /// Your extensions, as their toolbar buttons are: the icon, the badge, and whether each works on this site.
    private func buildExtensions() {
        // Extensions don't run in a private window, as in Chrome's incognito: none to show, nor to get here.
        // In Zigzag Mini, none: an extension's popup opens from a browser window's address.
        guard #available(macOS 15.4, *), controller != nil, let host = tab.extensionHost else { return }
        let actions = host.actions(for: tab)
        let installs = tab.profile.installs
        let offHere = !isBlank && ExtensionStore.extensionsOffSites.contains(site)
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
                                              run: { [weak self] _ in
                                                  guard let self, let controller = self.controller else { return }
                                                  host.performAction(action, tab: self.tab, in: controller)
                                              },
                                              menu: { [weak self] in self?.controller?.extensionMenu(for: context) })
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
            self?.controller?.tabManager.newTab(url: ExtensionStore.webStoreURL)
            self?.close()
        }, manage: { [weak self] in
            // Every extension, its sites and its pins: Settings › Extensions.
            guard let self, let controller = self.controller else { return }
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

    #if DEBUG
    /// pinhover <extension id> [pin] [limit] | none: the pointer on that extension's tile, or on its pin button, as a
    /// real pointer would put it there; none takes it off every tile. limit shows the tile's pin as it is at the limit,
    /// for a look without three extensions to pin.
    func debugHover(_ arg: String) { extensionsSection?.debugHover(arg) }
    #endif

    // What the rows of This Site say they're set to.
    private static let onHere = String(localized: "On for this site", comment: "Under a row's name in the site panel's This Site group, what it's set to: on.")
    private static let offHere = String(localized: "Off for this site", comment: "Under a row's name in the site panel's This Site group, what it's set to: off.")

    /// A choice in the Dark page row's dropdown.
    static func title(of choice: DarkPages.SiteChoice) -> String {
        switch choice {
        case .automatic: String(localized: "Automatic", comment: "A choice in the Dark page dropdown of the site panel: the site follows Settings › Appearance › Dark pages.")
        case .on: String(localized: "dark-page.on", defaultValue: "On", comment: "A choice in the Dark page dropdown of the site panel: this site's pages are drawn dark.")
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
        if #available(macOS 15.4, *) { context.extensionHost = controller != nil && tab.extensionHost != nil && !isBlank }
        context.hasExtensions = !(extensionsSection?.items.isEmpty ?? true)
        context.hasPermissions = origin.map { !SitePermissions.shown(origin: $0, isPrivate: isPrivate || tab.isPrivate).isEmpty } ?? false
        context.siteChoices = KeepAwake.isOffered(for: url, isPrivate: isPrivate)
        // Offered on a page with a video, or once chosen; the setting is in Settings › Tabs.
        context.fullScreen = PageFullScreen.isOffered(for: url, isPrivate: isPrivate)
            && (PageFullScreen.choice(for: url) != nil || tab.webView.map({ PageVideos.shared.frames(in: $0).contains { !$0.videos.isEmpty } }) == true)
        // Translating is a browser window's (`translatePage`).
        context.foreignLanguage = controller != nil && tab.foreignLanguage != nil
        context.coveredPage = controller?.isShowingReader == true || tab.pdfViewer != nil || tab.webView == nil
        return context
    }

    /// The Dark page row, while there is one.
    private weak var darkRow: PanelRow?

    private func buildRows() {
        rows = []
        zoomStepper = nil
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
                let blocked = !ContentBlocker.isAllowed(on: url)
                rows.append(.toggle(String(localized: "Ad blocking", comment: "Row in the site panel's This Site group."), on: blocked, status: { $0 ? Self.onHere : Self.offHere }) { [weak self] on in
                    guard let self else { return }
                    ContentBlocker.setAllowed(!on, on: self.url)
                    self.tab.reload()
                })
            case .cookieBanners:
                // Cookie banners (#175), for this site alone. What was done says so quietly, under its name.
                let banner = CookieBanners.outcome(in: tab.webView, site: site)
                let rejected = String(localized: "Rejected on this site", comment: "Under Cookie banners in the site panel's This Site group: Zigzag said no to the cookies the site's consent pop-up asked for.")
                let hidden = String(localized: "Hidden on this site", comment: "Under Cookie banners in the site panel's This Site group: the site's cookie notice was only hidden, since there was nothing to say no to.")
                let handledNow = CookieBanners.handles(url)
                rows.append(.toggle(String(localized: "Cookie banners", comment: "Row in the site panel's This Site group: whether Zigzag answers this site's cookie consent pop-ups with no."),
                                    on: handledNow, status: { on in
                                        guard on, on == handledNow else { return on ? Self.onHere : Self.offHere }
                                        return banner == .rejected ? rejected : banner == .hidden ? hidden : Self.onHere
                                    }) { [weak self] on in
                    guard let self else { return }
                    CookieBanners.setChoice(on, for: self.url)
                    if let webView = self.tab.webView { CookieBanners.forget(in: webView) }
                    self.tab.reload()
                })
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
            case .fullScreenFills:
                // Full screen in the page's own area instead of the whole screen (#168), for this site alone.
                rows.append(.toggle(String(localized: "Full screen fills the page", comment: "Row in the site panel's This Site group: a video's full screen on this site fills the page's area in the window instead of the whole screen."),
                                    on: PageFullScreen.fills(for: url) == .page, status: { $0 ? Self.onHere : Self.offHere }) { [weak self] on in
                    guard let self else { return }
                    PageFullScreen.setChoice(on ? .page : .screen, for: self.url)
                })
            case .extensions:
                // Whether extensions run here at all; off, every tile above dims and says so (#215).
                rows.append(.toggle(String(localized: "Extensions", comment: "Row in the site panel's This Site group."), on: !ExtensionStore.extensionsOffSites.contains(site),
                                    status: { $0 ? Self.onHere : Self.offHere }) { [weak self] on in
                    guard let self else { return }
                    var sites = ExtensionStore.extensionsOffSites
                    if on { sites.remove(self.site) } else { sites.insert(self.site) }
                    ExtensionStore.extensionsOffSites = sites
                    self.tab.reload()
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
    }

    /// The Permissions page: a row for each permission the site asked for this session or has an answer kept for,
    /// with Ask, Allow and Block; answers are the page's origin's, so another port or scheme on the same host has its
    /// own. Calls (Meet, Zoom, Teams) ask for the camera and microphone at once, and are one row; the answers of a
    /// call from elsewhere embedded in the page count there too. None asked, no page and no row into it.
    private func buildPermissions() {
        var permissionRows: [PanelRow] = []
        if let origin {
            let choices = PermissionChoice.allCases
            for permission in SitePermissions.shown(origin: origin, isPrivate: isPrivate || tab.isPrivate) {
                let now = SitePermissions.choice(permission, origin: origin)
                permissionRows.append(.choice(permission.title, options: choices.map(\.title), selected: choices.firstIndex(of: now) ?? 0) { [weak self] index in
                    SitePermissions.setChoice(choices[index], for: permission, origin: origin)
                    self?.refreshPermissionsRow()
                })
            }
        }
        if permissionsGroup.superview == nil { permissionsBox.addSubview(permissionsGroup) }
        permissionsGroup.rows = permissionRows
        if resetPermissions == nil, let origin {
            let row = PanelLinkRow(String(localized: "Reset Permissions", comment: "Row under a site's permissions in the site panel: forgets every answer given to the site, so it asks again.")) { [weak self] in
                SitePermissions.reset(origin: origin)
                self?.rebuildRows()
                // Nothing left to show there.
                self?.show(.main)
            }
            permissionsBox.addSubview(row)
            resetPermissions = row
        }
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
        row.isHidden = shown.isEmpty
        let choices = shown.map { SitePermissions.choice($0, origin: origin) }
        row.value = PermissionChoice.summary(choices)
        row.shortValue = PermissionChoice.shortSummary(choices)
        needsLayout = true
    }

    private func rebuildRows() {
        buildRows()
        resize()
    }

    /// Asks first: cookies sign you out of the site, and neither can be taken back.
    private func clear(_ kind: WebsiteData.Kind) {
        let tab = tab
        close()
        if let controller { controller.confirmClear(kind, of: tab) } else { mini?.confirmClear(kind, of: tab) }
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
        for box in [mainBox, permissionsBox] { box.frame = content.bounds }
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
        for box in [mainBox, permissionsBox] where !box.isHidden { place(box, NSRect(x: 0, y: 0, width: width, height: 10_000)) }
        func group(_ group: PanelGroup) {
            place(group, NSRect(x: pad, y: y, width: inner, height: group.height))
            y += group.height
        }

        switch page {
        case .permissions:
            group(permissionsGroup)
            if let resetPermissions {
                y += Tokens.Space.x2
                link(resetPermissions)
                end(0, slack: resetPermissions.bottomSlack)
            }
            return finish()
        case .main, .connection:
            break
        }

        // The extensions, below the actions (#215): folded to a header with their strip, or open as tiles.
        func extensions() {
            guard let section = extensionsSection else { return }
            let column = inner
            let h = section.height(for: column)
            place(section, NSRect(x: pad - PanelLinkRow.outset, y: y, width: column + PanelLinkRow.outset * 2, height: h))
            y += h
        }
        // A new tab has no site: the panel is your extensions alone.
        if isBlank {
            extensions()
            end(0, slack: extensionsSection.map { $0.isOpen || $0.items.isEmpty ? $0.bottomSlack : $0.foldedSlack } ?? 0)
            return finish()
        }

        // Header: the site's icon and name, and ⋯.
        let iconSide = Tokens.Space.x6
        let moreSide = Tokens.Metric.iconButton
        // The name, and under it the connection's line when there is one: the icon and ⋯ in the middle of both.
        let lineHeight = connectionLine == nil ? 0 : ConnectionLine.height
        let block = siteName.lineHeight + lineHeight
        let headerHeight = max(block, moreSide)
        let nameY = y + (headerHeight - block) / 2
        let moreX = width - pad - moreSide + Tokens.Space.x1
        place(moreButton, NSRect(x: moreX, y: y + (headerHeight - moreSide) / 2, width: moreSide, height: moreSide))
        place(icon, NSRect(x: pad, y: y + (headerHeight - iconSide) / 2, width: iconSide, height: iconSide))
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
        y += headerHeight
        // Why it isn't secure, when that isn't plain to see, under the whole header.
        if !connectionNote.isHidden {
            y += Tokens.Space.x2
            let w = inner + Label.inset * 2
            let h = ceil(connectionNote.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: w, height: 10_000)).height ?? connectionNote.lineHeight)
            place(connectionNote, NSRect(x: pad - Label.inset, y: y, width: w, height: h))
            y += h
        }
        end(Tokens.Space.x4)

        // Actions are named tiles: one row, like the markings along a device's edge. In a narrow panel, where a name
        // wouldn't show whole, they share even rows instead, never one left alone under the rest.
        if !actionTiles.isEmpty {
            let layout = Self.actionRows(count: actionTiles.count, width: inner,
                                         comfortable: actionTiles.map(\.captionWidth).max() ?? 0,
                                         tightest: actionTiles.map(\.captionTightWidth).max() ?? 0)
            Self.grid(actionTiles, columns: layout.first ?? 1, gap: 0, centered: true, height: PanelTile.captionedHeight,
                      x: pad, inner: inner, y: &y, place: place)
            end(Tokens.Space.x4)
        }

        // The developer tools of a development page that doesn't have them above it, under their own name, laid out as the actions are.
        if !developerTiles.isEmpty {
            place(developerLabel, NSRect(x: pad - Label.inset, y: y, width: inner + Label.inset * 2, height: developerLabel.lineHeight))
            y += developerLabel.lineHeight + Tokens.Space.x2
            let layout = Self.actionRows(count: developerTiles.count, width: inner,
                                         comfortable: developerTiles.map(\.captionWidth).max() ?? 0,
                                         tightest: developerTiles.map(\.captionTightWidth).max() ?? 0)
            Self.grid(developerTiles, columns: layout.first ?? 1, gap: 0, centered: true, height: PanelTile.captionedHeight,
                      x: pad, inner: inner, y: &y, place: place)
            end(Tokens.Space.x4)
        }

        if extensionsSection != nil {
            extensions()
            end(Tokens.Space.x3)
        }

        // One line into each of the other pages, each saying what's there; only those that apply.
        var c = SitePanelRows.Context()
        c.hasPermissions = permissionsRow?.isHidden == false
        let links = SitePanelRows.links(c)
        let linkRows: [(SitePanelRows.Link, PanelLinkRow?)] = [(.permissions, permissionsRow)]
        var placed = false
        for (kind, row) in linkRows {
            guard let row else { continue }
            row.isHidden = !links.contains(kind)
            guard !row.isHidden else { continue }
            if placed, gapAfter == 0 { y += PanelLinkRow.gap }
            link(row)
            placed = true
            end(0, slack: row.bottomSlack)
        }
        if placed { end(Tokens.Space.x4, slack: slack) }

        // This site's switches.
        if !rows.isEmpty {
            place(siteLabel, NSRect(x: pad - Label.inset, y: y, width: inner + Label.inset * 2, height: siteLabel.lineHeight))
            y += siteLabel.lineHeight + Tokens.Space.x2
            group(self.group)
            end(0, slack: self.group.bottomSlack)
        }
        return finish()
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

    /// Where a tile's pin button goes, in the panel's terms: its chip inside the tile's top-right corner, or the
    /// top-left when the tile has a count or a dot, so the two never meet. The target around the chip is the button's
    /// frame.
    static func pinFrame(on tile: NSRect, left: Bool) -> NSRect {
        let side = Tokens.Sidebar.hoverPin, chip = Tokens.Sidebar.hoverPinChip, inset = Tokens.Sidebar.hoverPinInset
        let chipX = left ? tile.minX + inset : tile.maxX - chip - inset
        let margin = (side - chip) / 2
        return NSRect(x: chipX - margin, y: tile.minY + inset - margin, width: side, height: side)
    }
}

/// The pin button on a corner of an extension's tile, as a favorite's close is on its tile: a small round chip with a
/// hairline and a pin glyph, inside the tile's corner. On a pinned extension it's always there, filled;
/// on another, only while the pointer or keyboard is on the tile, and one click pins it. At the limit it's dimmed and
/// only explains, in its tooltip. The tile stays one thing to the keyboard and VoiceOver, which reach pinning through
/// the tile's menu and actions.
final class HoverPin: InteractiveView {
    enum State { case unpinned, pinned, atLimit }

    /// On the panel's own color, so it reads cleanly over the icon under it in dark too.
    private let ground = ColorView(color: Tokens.Color.panelBackground)
    private let chip = ColorView(color: Tokens.Color.controlFill)
    private let icon = NSImageView()
    private(set) var isShowing = false
    /// The pointer or keyboard is on its tile.
    var isWanted = false { didSet { if isWanted != oldValue { updateShowing() } } }
    var state = State.unpinned {
        didSet {
            guard state != oldValue else { return }
            toolTipForState()
            // At the limit it only explains, in its tooltip: dimmed, and a click does nothing.
            isEnabled = state != .atLimit
            stateDidChange(animated: false)
            updateShowing()
        }
    }

    /// The glyph it shows: filled once pinned.
    var symbol: String { state == .pinned ? "pin.fill" : "pin" }
    /// The round chip it draws, in its own terms: the rest of it is target.
    var chipFrame: NSRect { chip.frame }

    init() {
        let side = Tokens.Sidebar.hoverPin, chipSide = Tokens.Sidebar.hoverPinChip
        super.init(frame: NSRect(x: 0, y: 0, width: side, height: side))
        isHidden = true
        chip.frame = NSRect(x: (side - chipSide) / 2, y: (side - chipSide) / 2, width: chipSide, height: chipSide)
        ground.frame = chip.frame
        ground.layer?.cornerRadius = chipSide / 2
        addSubview(ground)
        chip.layer?.cornerRadius = chipSide / 2
        chip.layer?.borderWidth = Tokens.Metric.hairline
        chip.edgeColor = Tokens.Color.controlEdge
        addSubview(chip)
        icon.imageScaling = .scaleNone
        addSubview(icon)
        setAccessibilityElement(false)
        toolTipForState()
        stateDidChange(animated: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { false }

    private func toolTipForState() {
        toolTip = state == .pinned ? SitePanel.unpinTitle : state == .atLimit ? SitePanel.pinLimitTip : SitePanel.pinTitle
    }

    private func updateShowing() { setShowing(state == .pinned || isWanted) }

    /// Fades in and out where it is; from the keyboard it's simply there.
    private func setShowing(_ showing: Bool) {
        guard showing != isShowing else { return }
        isShowing = showing
        if showing {
            isHidden = false
            // A pointer already over it, when the tile brought it up, gets no "entered".
            if let window { isHovered = bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) }
        }
        guard window != nil, !Tokens.Motion.isFromKey else {
            Tokens.Motion.settle(self)
            isHidden = !showing
            return
        }
        Tokens.Motion.present(self, from: .inPlace, entering: showing) { [weak self] in
            // Shown again while going: it stays.
            guard let self, !self.isShowing else { return }
            self.isHidden = true
            Tokens.Motion.settle(self)
        }
    }

    override func stateDidChange(animated: Bool) {
        let glyph = Tokens.Sidebar.hoverPinGlyph
        icon.image = Tokens.Symbol.image(symbol, size: glyph)
        // The glyph's ink, not its image, in the chip's middle.
        let ink = Tokens.Symbol.inkOffset(symbol, size: glyph)
        icon.frame = chip.frame.offsetBy(dx: -ink.width, dy: ink.height)
        // Secondary ink at rest, the primary under the pointer, over the hover wash; dimmed at the limit.
        let hot = isHovered && isEnabled
        icon.contentTintColor = hot ? Tokens.Color.textPrimary : Tokens.Color.textSecondary
        icon.alphaValue = isEnabled ? 1 : Tokens.Opacity.disabled
        chip.color = hot ? Tokens.Color.controlHover : Tokens.Color.controlFill
    }
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

    var height: CGFloat { CGFloat(rows.count) * PanelRow.height }
    /// The room left under the last row's words inside its row: the panel's bottom margin counts from the words,
    /// as its top does, so this much less is added there.
    var bottomSlack: CGFloat { rows.last.map { (PanelRow.height - $0.contentHeight) / 2 } ?? 0 }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        for (i, row) in rows.enumerated() {
            row.frame = NSRect(x: 0, y: CGFloat(i) * PanelRow.height, width: bounds.width, height: PanelRow.height)
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

    /// A name and a dropdown of choices: a permission's Ask, Allow or Block. With `status`, what the choice means
    /// right now sits under the name, read again once a choice has been made (Dark page's "On, following Settings").
    static func choice(_ title: String, options: [String], selected: Int, status: ((Int) -> String?)? = nil, chose: @escaping (Int) -> Void) -> PanelRow {
        let dropdown = DropdownButton()
        dropdown.options = options.map { DropdownButton.Option(title: $0) }
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

    #if DEBUG
    /// Its name, and what its dropdown or switch is set to.
    var debugTitle: String {
        if let dropdown = control as? DropdownButton {
            return "\(title.stringValue): \(dropdown.accessibilityValue() as? String ?? "")" + (value.flatMap { $0.isHidden ? nil : " (\($0.stringValue))" } ?? "")
        }
        if let toggle = control as? Toggle { return "\(title.stringValue): \(toggle.isOn ? "on" : "off")" }
        return title.stringValue
    }

    /// choose <index>: picks that choice in the row's dropdown, as its menu would.
    func debugChoose(_ index: Int) {
        guard let dropdown = control as? DropdownButton, dropdown.options.indices.contains(index) else { return }
        dropdown.selectedIndex = index
        dropdown.onSelect?(index)
    }
    #endif

    override func layout() {
        super.layout()
        let size = control.fittingSize.width > 0 ? control.fittingSize : control.intrinsicContentSize
        control.frame = NSRect(x: bounds.width - size.width, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
        let x = -Label.inset
        let right = control.frame.minX - Tokens.Space.x2 - x
        guard let value, !value.isHidden else {
            // A long name beside its control ("Camera and microphone" by a dropdown) takes a second line rather than
            // being cut short; the row has room for two.
            let twoLines = title.textWidth > right
            title.usesSingleLineMode = !twoLines
            title.maximumNumberOfLines = twoLines ? 2 : 1
            title.lineBreakMode = twoLines ? .byWordWrapping : .byTruncatingTail
            title.cell?.wraps = twoLines
            let h = twoLines ? min(ceil(title.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: right, height: 200)).height ?? title.lineHeight), bounds.height) : title.lineHeight
            title.frame = NSRect(x: x, y: (bounds.height - h) / 2, width: right, height: h)
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
    /// The room under the words inside the row: the panel's bottom margin counts from the words.
    var bottomSlack: CGFloat { (Self.height - title.lineHeight) / 2 }
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

    /// Its name, for a row that says something else after a click (Show All, Show Less).
    var titleText: String {
        get { title.stringValue }
        set { title.stringValue = newValue; setAccessibilityLabel(newValue); needsLayout = true }
    }

    override func layout() {
        super.layout()
        let side = Tokens.Space.x4
        chevron.frame = NSRect(x: bounds.width - Self.outset - side, y: (bounds.height - side) / 2, width: side, height: side)
        let right = chevron.isHidden ? bounds.width - Self.outset : chevron.frame.minX - Tokens.Space.x1
        // The name whole, the value in the room left; a value too long for it says it the short way.
        let room = right - Self.outset - title.textWidth - Tokens.Space.x2
        if let shortValue, !value.isEmpty {
            valueLabel.stringValue = fullValue(fits: room) ? value : shortValue
        }
        let valueWidth = value.isEmpty ? 0 : max(0, min(valueLabel.textWidth, max(room, (right - Self.outset) / 3)))
        valueLabel.frame = NSRect(x: right - valueWidth + Label.inset, y: (bounds.height - valueLabel.lineHeight) / 2, width: valueWidth, height: valueLabel.lineHeight)
        let titleRight = value.isEmpty ? right : right - valueWidth - Tokens.Space.x1
        title.frame = NSRect(x: Self.outset - Label.inset, y: (bounds.height - title.lineHeight) / 2,
                             width: titleRight - Self.outset + Label.inset * 2, height: title.lineHeight)
    }

    override func stateDidChange(animated: Bool) {
        // A row that goes nowhere (Connection on a plain http page) only says what it says: no wash.
        if isEnabled { applyRowStyle(animated: animated) } else { layer?.backgroundColor = nil }
        chevron.contentTintColor = Tokens.Color.textTertiary
    }
}

/// − 100% +: the page's zoom a step out or in, and the percentage, which sets it back to 100%.
final class ZoomStepper: NSView {
    private let minus = IconButton(symbol: "minus", size: .compact, toolTip: String(localized: "Zoom Out", comment: "Tooltip of the − button on the Zoom row of the site panel."))
    private let plus = IconButton(symbol: "plus", size: .compact, toolTip: String(localized: "Zoom In", comment: "Tooltip of the + button on the Zoom row of the site panel."))
    private let percent = PillButton(title: "100%", style: .quiet)
    /// The zoom now, as the page has it.
    var zoom: CGFloat = 1 { didSet { refresh() } }
    var onChange: ((CGFloat) -> Void)?

    /// Wide enough for any step ("300%"), so the buttons around it never move.
    private var percentWidth: CGFloat {
        ceil(("300%" as NSString).size(withAttributes: [.font: Tokens.Font.control()]).width) + Tokens.Space.x4
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        percent.toolTip = String(localized: "Actual Size", comment: "Tooltip of the percentage on the Zoom row of the site panel: sets the page back to 100%.")
        [minus, percent, plus].forEach { addSubview($0) }
        minus.onClick = { [weak self] _ in self?.go(-1) }
        plus.onClick = { [weak self] _ in self?.go(1) }
        percent.onClick = { [weak self] _ in self?.set(1) }
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
        default: set(1)
        }
    }
    #endif

    private func go(_ direction: Int) {
        guard ZoomLevels.canStep(zoom, by: direction) else { return }
        set(ZoomLevels.step(zoom, by: direction))
    }

    private func set(_ value: CGFloat) {
        guard abs(value - zoom) > 0.001 else { return }
        zoom = value
        onChange?(value)
    }

    private func refresh() {
        percent.title = ZoomLevels.percent(zoom)
        percent.setAccessibilityLabel(String(localized: "Zoom \(ZoomLevels.percent(zoom)), Actual Size", comment: "VoiceOver name of the percentage on the Zoom row of the site panel: the zoom now, then what pressing it does."))
        minus.isEnabled = ZoomLevels.canStep(zoom, by: -1)
        plus.isEnabled = ZoomLevels.canStep(zoom, by: 1)
    }

    override func layout() {
        super.layout()
        let side = Tokens.Metric.compactIconButton
        minus.frame = NSRect(x: 0, y: (bounds.height - side) / 2, width: side, height: side)
        percent.frame = NSRect(x: side, y: 0, width: percentWidth, height: bounds.height)
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
    /// The lock, the words and the chevron, and no more.
    var fittingWidth: CGFloat { ceil(side + Tokens.Space.x1 + label.inkWidth + (opens ? 2 + side : 0)) }

    override func layout() {
        super.layout()
        glyph.frame = NSRect(x: 0, y: (bounds.height - side) / 2, width: side, height: side)
        let x = side + Tokens.Space.x1
        let room = max(0, bounds.width - x - (opens ? 2 + side : 0))
        let w = min(label.inkWidth, room)
        label.frame = NSRect(x: x - Label.inset, y: (bounds.height - label.lineHeight) / 2, width: w + Label.inset * 2, height: label.lineHeight)
        chevron.frame = NSRect(x: x + w + 2, y: (bounds.height - side) / 2, width: side, height: side)
    }

    override func stateDidChange(animated: Bool) {
        // No wash: the words step up under the pointer. Not secure always stands out.
        let hot = isHovered && isEnabled
        let ink = warns ? Tokens.Color.warning : hot ? Tokens.Color.textSecondary : Tokens.Color.textTertiary
        label.textColor = ink
        glyph.contentTintColor = ink
        chevron.contentTintColor = hot ? (warns ? Tokens.Color.warning : Tokens.Color.textSecondary) : Tokens.Color.textTertiary
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
        // The back glyph's ink on the panel's text column, the title after it.
        let side = Tokens.Metric.compactIconButton
        let ink = (side - Tokens.Symbol.compactGlyph) / 2
        back.frame = NSRect(x: -ink, y: (bounds.height - side) / 2, width: side, height: side)
        let x = showsBack ? side - ink + Tokens.Space.x1 : 0
        label.frame = NSRect(x: x - Label.inset, y: (bounds.height - label.lineHeight) / 2, width: bounds.width - x + Label.inset * 2, height: label.lineHeight)
    }
}

/// How tall Site Controls is, and how much of a page scrolls (#220): never past the window's bottom, a page's header
/// kept at the top, and the rest of the page under it scrolling when it doesn't fit.
enum SitePanelSizing {
    /// The tallest the panel can be from `top` in a window's overlay `overlayHeight` tall: down to the window's bottom
    /// inset, and never so short that a page can't show a few rows.
    static func maxHeight(overlayHeight: CGFloat, top: CGFloat) -> CGFloat {
        max(PanelLinkRow.height * 4, overlayHeight - top - Tokens.Metric.cardInset)
    }

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
    enum Row: Equatable { case zoom, adBlocking, cookieBanners, darkPage, keepAwake, fullScreenFills, alwaysTranslate, extensions }
    /// The rows into the panel's other pages. Extensions are on the first page itself (#215), and the connection is a
    /// small line under the site's name (#221).
    enum Link: Equatable { case permissions }

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
        /// Full screen in the page is offered here, and the page has a video or a choice was made.
        var fullScreen = false
        /// The page is in a language other than yours.
        var foreignLanguage = false
        /// Reader or a PDF covers the page: the page's zoom isn't what you see.
        var coveredPage = false
        /// The site asked for something, or has an answer kept.
        var hasPermissions = false
        /// Extensions run in this window (never a private one).
        var extensionHost = true
        /// There are extensions to run, or not, on this site.
        var hasExtensions = false
    }

    static func rows(_ c: Context) -> [Row] {
        var rows: [Row] = []
        if c.isWeb, !c.coveredPage { rows.append(.zoom) }
        if c.isWeb, c.adBlocking, !c.isPrivate { rows.append(.adBlocking) }
        if c.isWeb, c.cookieBanners, !c.isPrivate { rows.append(.cookieBanners) }
        if c.siteChoices {
            rows.append(.darkPage)
            rows.append(.keepAwake)
        }
        if c.fullScreen { rows.append(.fullScreenFills) }
        if c.foreignLanguage { rows.append(.alwaysTranslate) }
        // Whether extensions run here: on a web site, once there are extensions to run.
        if c.isWeb, !c.isPrivate, c.extensionHost, c.hasExtensions { rows.append(.extensions) }
        return rows
    }

    static func links(_ c: Context) -> [Link] {
        var links: [Link] = []
        if c.hasPermissions { links.append(.permissions) }
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
