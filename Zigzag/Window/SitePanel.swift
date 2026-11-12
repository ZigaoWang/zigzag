import AppKit
import WebKit

/// Everything about the page you're on, behind one button by the address (#174). Its first page is short: the site,
/// a row of quick actions, one line each into Connection (the certificate), Permissions (once the site asked) and
/// Extensions, and the few switches that apply to this page. Each of those lines opens a page of its own in the same
/// panel, with a way back. Rarer things (installing the site as an app, clearing its cookies or cache) wait in the
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
    private weak var anchor: NSView?
    /// The button it opened from, shown pressed while it's open: the sidebar's, or a split pane's (#160).
    private weak var opener: IconButton?
    private var monitor: Any?
    private let tab: Tab
    /// A private window's, even on a new tab with no page yet: no extensions there.
    private let isPrivate: Bool
    private let url: URL
    private let site: String
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
    private let moreButton = IconButton(symbol: "ellipsis", toolTip: String(localized: "More", comment: "Tooltip of the … button in the site panel."))
    private var actionTiles: [PanelTile] = []
    /// Whose extensions these are, at the label's end, once there's more than one profile.
    private let extensionsProfileLabel = Label("", font: Tokens.Font.label(), color: Tokens.Color.textTertiary)
    private var extensionTiles: [PanelTile] = []
    /// No extensions: the + is alone, with its name under it.
    private var addsAlone = false
    /// The pin button on each extension's tile: the panel's child over the tile, a control of its own.
    private var hoverPins: [(id: String, label: String, value: String?, tile: PanelTile, pin: HoverPin)] = []
    private var extensionsToken: SignalToken?
    private let siteLabel = Label.section(String(localized: "This Site", comment: "Section label over the site's settings in the site panel."))
    private var rows: [PanelRow] = []
    private let group = PanelGroup()
    /// The ways into the panel's pages, one line each with what's there: Connection, Permissions, Extensions on
    /// This Site. Only those that apply.
    private var connectionRow: PanelLinkRow?
    private var permissionsRow: PanelLinkRow?
    private var extensionsRow: PanelLinkRow?
    /// Settings › Extensions, under the extensions.
    private var manageExtensions: PanelLinkRow?
    /// On the Extensions page: whether extensions run on this site.
    private let extensionsSwitch = PanelGroup()
    private let permissionsGroup = PanelGroup()
    private var resetPermissions: PanelLinkRow?
    private let permissionsHeader = PanelPageHeader(String(localized: "Permissions", comment: "Row in the site panel, and the title of its page: the site's camera, location, notifications and pop-ups."))
    private let extensionsHeader = PanelPageHeader(SitePanel.extensionsTitle)
    /// The certificate, its own page while it's open.
    private var certificatePage: CertificatePage?
    private var zoomStepper: ZoomStepper?

    /// The panel's pages: the site at a glance, and one each for what's behind its rows.
    enum Page: String { case main, connection, permissions, extensions }
    private(set) var page = Page.main
    var showsSubpage: Bool { page != .main && !(isBlank && page == .extensions) }
    private let mainBox = FlippedView()
    private let permissionsBox = FlippedView()
    private let extensionsBox = FlippedView()
    static let extensionsTitle = String(localized: "Extensions on This Site", comment: "Row in the site panel, and the title of its page: the extensions, whether they run on this site, and a way to manage them.")

    /// The panel's content, in a sheet that scrolls when the window is too short for it.
    private let scroll = NSScrollView()
    private let content = FlippedView()
    private var contentReady = false
    /// The tallest it can be where it opened: down to the window's bottom.
    fileprivate var maxHeight: CGFloat = .greatestFiniteMagnitude

    static let width: CGFloat = 300
    /// How a plain http page is marked, here and in the address bar: one symbol and one wording.
    static let notSecure = String(localized: "Not secure", comment: "How a page loaded over plain http is marked, in the site panel and the address bar's tooltip.")
    static let notSecureSymbol = "lock.open.fill"
    static let pinTitle = String(localized: "Pin to Address", comment: "Item in an extension's menu, tooltip of the pin on its tile in the site panel, and VoiceOver action: gives the extension a button in the address bar.")
    static let unpinTitle = String(localized: "Unpin from Address", comment: "Item in an extension's menu, tooltip of the pin on its tile in the site panel, and VoiceOver action: takes the extension's button out of the address bar.")
    static var pinLimitTip: String { String(localized: "At most \(ExtensionPins.limit) pins. Unpin one first.", comment: "Tooltip of the pin on an extension's tile, and of the disabled menu item, when the most extensions that can be pinned already are. The number is that limit.") }
    static let minimumWidth: CGFloat = 256
    private var width: CGFloat = SitePanel.width
    private var pad: CGFloat { width < Self.width ? Tokens.Space.x3 : Tokens.Space.x4 }

    private init?(controller: BrowserWindowController, tab asked: Tab?) {
        // With no page (a new tab), it still opens: your extensions are always one click away.
        let tab = asked ?? controller.tabManager.selectedTab ?? Tab(url: nil, spaceID: controller.tabManager.currentSpaceID)
        let url = tab.url.flatMap { ["http", "https", "webkit-extension"].contains($0.scheme ?? "") ? $0 : nil }
        isBlank = url == nil
        self.controller = controller
        self.tab = tab
        isPrivate = tab.isPrivate || controller.tabManager.isPrivate
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
        [mainBox, permissionsBox, extensionsBox].forEach { content.addSubview($0) }
        contentReady = true
        permissionsHeader.onBack = { [weak self] in self?.show(.main) }
        extensionsHeader.onBack = { [weak self] in self?.show(.main) }
        permissionsBox.addSubview(permissionsHeader)
        extensionsBox.addSubview(extensionsHeader)
        radius = Tokens.Radius.panel
        icon.image = tab.favicon
        // In the app's voice, as a page names itself; a site's name keeps its own spelling. Plain http or a port of
        // its own is named in full, as its answers are its own: localhost:3000 never reads like localhost:3001.
        let web = ["http", "https"].contains(url?.scheme?.lowercased() ?? "")
        let full = origin.map(SiteOrigin.label).flatMap { $0.contains(":") ? $0 : nil }
        let named = web ? full ?? site : site
        siteName.attributedStringValue = Tokens.Font.voiceText(named, size: 20)
        let address = self.url
        if ["http", "https"].contains(address.scheme ?? "") {
            // The connection, by its one word: secure, or not. Only an https page has a certificate to show; plain
            // http just says it's not secure. An extension's own page never crosses the network: no row.
            let secure = address.scheme == "https" && (tab.webView?.hasOnlySecureContent ?? true)
            let opens = address.scheme == "https" && tab.webView?.serverTrust != nil
            let value = secure ? String(localized: "Secure", comment: "On the Connection row of the site panel: the page came over https.")
                : address.scheme == "https" ? String(localized: "Partly secure", comment: "On the Connection row of the site panel: an https page with some parts loaded over plain http.")
                : Self.notSecure
            let row = PanelLinkRow(String(localized: "Connection", comment: "Row in the site panel: whether the page's connection is secure. On an https page it opens the site's certificate."),
                                   value: value, goes: opens) { [weak self] in self?.showCertificate() }
            row.isEnabled = opens
            if !secure { row.valueColor = Tokens.Color.warning }
            connectionRow = row
        }
        [icon, siteName, moreButton].forEach { addSubview($0) }
        if let connectionRow { addSubview(connectionRow) }
        let shownSite = site
        pageToken = tab.changed.observe { [weak self, weak tab] change in
            guard change == .url, let self, let now = tab?.url else { return }
            if (ContentBlocker.site(of: now) ?? now.host() ?? now.absoluteString) != shownSite || SiteOrigin.of(now) != origin { self.close() }
        }
        moreButton.onClick = { [weak self] _ in self?.showMoreMenu() }
        moreButton.isHidden = !canClear
        buildExtensions()
        if isBlank {
            // No page: only your extensions, one click away, on a page of their own with nowhere to go back to.
            extensionsHeader.title = String(localized: "Extensions", comment: "Title of the site panel on a new tab, over your extensions.")
            extensionsHeader.showsBack = false
            page = .extensions
        } else {
            buildTiles()
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
        panel.maxHeight = max(PanelLinkRow.height * 4, controller.root.overlay.bounds.height - panel.frame.minY - Tokens.Metric.cardInset)
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
        panel.monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak panel] event in
            // Only its own window: keys and clicks in Settings or another window are theirs. A menu open over it
            // takes Esc and the click that closes it.
            guard let panel, event.window === panel.window, MenuPanel.current == nil else { return event }
            if event.type == .keyDown {
                // Esc on one of its pages goes back; on the panel, it closes.
                if event.keyCode == 53 {
                    if panel.showsSubpage { panel.show(.main) } else { panel.close() }
                    return nil
                }
                return event
            }
            let inside = panel.bounds.contains(panel.convert(event.locationInWindow, from: nil))
            let onAnchor = panel.anchor.map { $0.bounds.contains($0.convert(event.locationInWindow, from: nil)) } ?? false
            if !inside && !onAnchor { panel.close() }
            return event
        }
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
        guard let controller else { return }
        let readerOn = controller.isShowingReader
        // (symbol, caption, full name for the tooltip and VoiceOver, on, action)
        var specs: [(String, String, String, Bool, () -> Void)] = []
        let share = String(localized: "Share", comment: "Action in the site panel: shares the page.")
        specs.append(("square.and.arrow.up", share, share, false, { [weak self] in self?.close(); self?.controller?.sharePage(nil) }))
        let copyLink = String(localized: "Copy Link", comment: "Action in the site panel: copies the page's address.")
        specs.append(("link", copyLink, copyLink, false, { [weak self] in
            guard let self else { return }
            self.controller?.copyLink(self.url)
            self.close()
        }))
        if PageScreenshot.canTake(tab), !readerOn {
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
        specs.append(("translate",
                      tab.isTranslated ? String(localized: "Original", comment: "Action in the site panel, under its icon: shows the translated page as it was.") : translate,
                      tab.isTranslated ? String(localized: "Show Original", comment: "Tooltip of the Original action in the site panel.") : translate,
                      tab.isTranslated, { [weak self] in self?.controller?.translatePage(); self?.close() }))
        if tab.isArticle || readerOn {
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
                          floating, { [weak self] in self?.controller?.togglePictureInPicture(nil); self?.close() }))
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
        if let shown = [mainBox, permissionsBox, extensionsBox, certificatePage].compactMap({ $0 }).first(where: { !$0.isHidden }) {
            Tokens.Motion.present(shown, from: .inPlace, entering: true)
        }
    }

    /// Only the page's own views show.
    private func applyPage() {
        mainBox.isHidden = page != .main
        permissionsBox.isHidden = page != .permissions
        extensionsBox.isHidden = page != .extensions
        // The pins keep their own showing: one that faded while another page was up stays as it is now.
        if page == .extensions { refreshHoverPins() }
    }

    /// The certificate, read from the trust WebKit checked the page with.
    private func showCertificate() {
        guard page != .connection, let trust = tab.webView?.serverTrust else { return }
        let certificate = CertificatePage()
        certificate.onBack = { [weak self] in self?.show(.main) }
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

    /// As tall as its content, up to `maxHeight`.
    fileprivate var fittedHeight: CGFloat { min(layoutContent(dryRun: true), maxHeight) }

    /// The site at a glance goes in its own page; the other pages add theirs where they're built.
    override func addSubview(_ view: NSView) {
        if contentReady { mainBox.addSubview(view) } else { super.addSubview(view) }
    }

    #if DEBUG
    /// sitepage <main|connection|permissions|extensions>: goes to that page, as its row or back button does.
    func debugPage(_ arg: String) {
        guard let next = Page(rawValue: arg) else { return }
        if next == .connection { showCertificate() } else { show(next) }
    }

    /// What the panel shows, for checking it without looking: its page, and its rows' names, top to bottom.
    var debugState: [String: Any] {
        ["site": site, "page": page.rawValue, "certificate": certificatePage?.debugState ?? [:],
         "links": [connectionRow, permissionsRow, extensionsRow].compactMap { $0 }.filter { !$0.isHidden }.map(\.debugTitle),
         "rows": rows.map(\.debugTitle), "permissions": permissionsGroup.rows.map(\.debugTitle),
         "extensionsSwitch": extensionsSwitch.rows.map(\.debugTitle),
         "zoom": zoomStepper.map { ZoomLevels.percent($0.zoom) } ?? ""]
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

    private func buildExtensions() {
        // Extensions don't run in a private window, as in Chrome's incognito: none to show, nor to get here.
        guard #available(macOS 15.4, *), let host = tab.extensionHost else { return }
        let items = host.actions(for: tab)
        extensionTiles = items.map { item in
            let tile = PanelTile(image: item.icon, symbol: "puzzlepiece.extension", caption: nil)
            tile.toolTip = item.attention != nil ? String(localized: "\(item.label): needs attention", comment: "Tooltip of an extension's button in the site panel when the extension asks for attention. The name is the extension's.") : item.label
            // VoiceOver reads the extension's name, then what its badge says.
            tile.setAccessibilityLabel(item.label)
            let value = item.attention != nil ? String(localized: "Needs attention", comment: "VoiceOver value of an extension's button in the site panel when the extension asks for attention.") : item.badge.isEmpty ? nil : item.badge
            // Attention first: the badge takes its look from it.
            tile.isAttention = item.attention != nil
            tile.badge = item.attention != nil ? "!" : item.badge
            tile.onClick = { [weak self] _ in
                guard let self, let controller = self.controller else { return }
                host.performAction(item, tab: self.tab, in: controller)
            }
            tile.onRightClick = { [weak self] _ in self?.controller?.extensionMenu(for: item.context) }
            extensionsBox.addSubview(tile)
            hoverPins.append((item.id, item.label, value, tile, HoverPin()))
            return tile
        }
        // With none yet, the + says what it does under it, as the actions above do; after the extensions, it's one of them.
        let getTitle = String(localized: "Get Extensions", comment: "Tooltip and VoiceOver name of the + button after the extensions in the site panel: opens the Chrome Web Store.")
        let add = PanelTile(symbol: "plus", caption: items.isEmpty ? getTitle : nil)
        add.toolTip = getTitle
        add.setAccessibilityLabel(getTitle)
        addsAlone = items.isEmpty
        add.onClick = { [weak self] _ in
            self?.controller?.tabManager.newTab(url: ExtensionStore.webStoreURL)
            self?.close()
        }
        extensionsBox.addSubview(add)
        extensionTiles.append(add)
        extensionsProfileLabel.alignment = .right
        extensionsProfileLabel.lineBreakMode = .byTruncatingTail
        extensionsBox.addSubview(extensionsProfileLabel)
        // Every extension, its sites and its pins: Settings › Extensions, one row under them.
        let manage = PanelLinkRow(String(localized: "Manage Extensions", comment: "Row under the extensions in the site panel: opens Settings › Extensions."), goes: true) { [weak self] in
            guard let self, let controller = self.controller else { return }
            self.close()
            SettingsPage.open(.extensions, in: controller)
        }
        extensionsBox.addSubview(manage)
        manageExtensions = manage
        // Over its tile.
        for entry in hoverPins {
            extensionsBox.addSubview(entry.pin)
            wireHoverPin(entry.tile, entry.pin, id: entry.id)
        }
        refreshHoverPins()
        extensionsToken = ExtensionCenter.changed.observe { [weak self] in self?.refreshHoverPins() }
        guard !isBlank else { return }
        // On the main page, one line: how many there are, or that they're off here.
        let count = items.count
        let value: (Bool) -> String = { off in
            off ? String(localized: "Off", comment: "On the Extensions on This Site row of the site panel: extensions don't run on this site.")
                : count == 0 ? String(localized: "None", comment: "On the Extensions on This Site row of the site panel: no extensions are installed.") : "\(count)"
        }
        let off = ExtensionStore.extensionsOffSites.contains(site)
        let row = PanelLinkRow(String(localized: "Extensions", comment: "Row in the site panel's This Site group."), value: value(off), goes: true) { [weak self] in self?.show(.extensions) }
        addSubview(row)
        extensionsRow = row
        // Whether they run here: on a web site, once there are extensions to run.
        if count > 0, ["http", "https"].contains(url.scheme ?? ""), !isPrivate {
            let toggle = PanelRow.toggle(String(localized: "Extensions", comment: "Row in the site panel's This Site group."), on: !off,
                                         status: { $0 ? Self.onHere : Self.offHere }) { [weak self, weak row] on in
                guard let self else { return }
                var sites = ExtensionStore.extensionsOffSites
                if on { sites.remove(self.site) } else { sites.insert(self.site) }
                ExtensionStore.extensionsOffSites = sites
                row?.value = value(!on)
                self.tab.reload()
            }
            extensionsSwitch.rows = [toggle]
            extensionsBox.addSubview(extensionsSwitch)
        }
    }

    private func wireHoverPin(_ tile: PanelTile, _ pin: HoverPin, id: String) {
        let installs = tab.profile.installs
        pin.onClick = { _ in installs.togglePin(id) }
        // The pointer on the tile or on the pin; or the keyboard on the tile.
        let update: (Bool) -> Void = { [weak tile, weak pin] _ in
            guard let tile, let pin else { return }
            pin.isWanted = tile.isHovered || tile.hasKeyboardFocus || (pin.isShowing && pin.isHovered)
        }
        tile.hoverChanged = update
        tile.keyboardFocusChanged = update
        pin.hoverChanged = update
    }

    #if DEBUG
    /// pinhover <extension id> [pin] [limit] | none: the pointer on that extension's tile, or on its pin button, as a
    /// real pointer would put it there; none takes it off every tile. limit shows the tile's pin as it is at the limit,
    /// for a look without three extensions to pin.
    func debugHover(_ arg: String) {
        let f = arg.split(separator: " ").map(String.init)
        for entry in hoverPins where entry.id != f.first {
            entry.pin.isHovered = false
            entry.tile.isHovered = false
        }
        guard let entry = hoverPins.first(where: { $0.id == f.first }) else { return }
        if f.contains("limit") { entry.pin.state = .atLimit }
        entry.tile.isHovered = true
        if f.contains("pin") { entry.pin.isHovered = true }
    }
    #endif

    /// What each pin says now. Runs on every change, from here or another window, so the limit is always the truth.
    private func refreshHoverPins() {
        // A count that came or went moves the pin to the other corner.
        needsLayout = true
        let installs = tab.profile.installs
        let pins = installs.pins
        for entry in hoverPins {
            let pinned = pins.contains(entry.id)
            let id = entry.id
            entry.pin.state = pinned ? .pinned : installs.canPin(id) ? .unpinned : .atLimit
            let state = pinned ? String(localized: "Pinned", comment: "VoiceOver value of an extension's button in the site panel when it's pinned to the address bar.") : nil
            entry.tile.setAccessibilityValue([entry.value, state].compactMap { $0 }.joined(separator: ", "))
            entry.tile.setAccessibilityCustomActions(entry.pin.state == .atLimit ? nil : [
                NSAccessibilityCustomAction(name: pinned ? Self.unpinTitle : Self.pinTitle) {
                    MainActor.assumeIsolated { installs.togglePin(id) }
                    return true
                },
            ])
        }
    }

    // What the rows of This Site say they're set to.
    private static let onHere = String(localized: "On for this site", comment: "Under a row's name in the site panel's This Site group, what it's set to: on.")
    private static let offHere = String(localized: "Off for this site", comment: "Under a row's name in the site panel's This Site group, what it's set to: off.")

    /// Which rows apply to this page, as `SitePanelRows` decides from what the page is.
    private var rowContext: SitePanelRows.Context {
        var context = SitePanelRows.Context()
        context.isWeb = ["http", "https"].contains(url.scheme ?? "")
        context.isPrivate = isPrivate
        context.adBlocking = ContentBlocker.isEnabled
        // Once a consent pop-up was found on the page, or a choice was made for the site (#175).
        context.cookieBanners = CookieBanners.applies(to: url)
            && (CookieBanners.outcome(in: tab.webView, site: site) != nil || CookieBanners.choice(for: url) != nil)
        if #available(macOS 15.4, *) { context.extensionHost = tab.extensionHost != nil && !isBlank }
        context.hasPermissions = origin.map { !SitePermissions.shown(origin: $0, isPrivate: isPrivate || tab.isPrivate).isEmpty } ?? false
        context.siteChoices = KeepAwake.isOffered(for: url, isPrivate: isPrivate)
        context.forceDarkOffered = tab.darkPage?.native == true || DarkPages.isForced(url)
        // Offered on a page with a video, or once chosen; the setting is in Settings › Tabs.
        context.fullScreen = PageFullScreen.isOffered(for: url, isPrivate: isPrivate)
            && (PageFullScreen.choice(for: url) != nil || tab.webView.map({ PageVideos.shared.frames(in: $0).contains { !$0.videos.isEmpty } }) == true)
        context.foreignLanguage = tab.foreignLanguage != nil
        context.coveredPage = controller?.isShowingReader == true || tab.pdfViewer != nil || tab.webView == nil
        return context
    }

    private func buildRows() {
        rows = []
        zoomStepper = nil
        // Each is offered only where it does something (`SitePanelRows`). The choices kept for a site (ad blocking,
        // dark pages, keeping tabs awake) aren't offered in a private window: its site would be kept in Settings ›
        // Privacy › Sites. Its tabs still follow the ones made elsewhere.
        weak var darkRow: PanelRow?
        weak var forceRow: PanelRow?
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
                // Dark pages, for this site alone: on here though off everywhere else, or the other way round. A site
                // that's dark on its own says so: there's nothing for Zigzag to darken.
                let native = String(localized: "This site is dark already", comment: "Under Dark page in the site panel's This Site group: dark pages are on, and the site has a dark look of its own, so it's left as it is.")
                let tab = tab, url = url
                let row = PanelRow.toggle(String(localized: "Dark page", comment: "Row in the site panel's This Site group: draws this site's pages dark."), on: DarkPages.wants(url),
                                          status: { on in on && tab.darkPage?.native == true && !DarkPages.isForced(url) ? native : on ? Self.onHere : Self.offHere }) { [weak self] on in
                    guard let self else { return }
                    DarkPages.setChoice(on, for: self.url)
                    if !on { forceRow?.setOn(false) }
                }
                darkRow = row
                rows.append(row)
            case .forceDark:
                // Force dark (#134): for a site that looks dark on its own but leaves parts light, or says it's dark
                // and isn't. Offered where that's so, or once it's on.
                let row = PanelRow.toggle(String(localized: "Force dark", comment: "Row in the site panel's This Site group, under Dark page: draws this site dark even though it looks dark on its own, for a site that leaves parts of itself light."),
                                          on: DarkPages.isForced(url), status: { $0 ? Self.onHere : Self.offHere }) { [weak self] on in
                    guard let self else { return }
                    DarkPages.setForced(on, for: self.url)
                    darkRow?.setOn(DarkPages.wants(self.url))
                }
                forceRow = row
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
        let site = site, tab = tab
        close()
        guard let controller else { return }
        let cookies = kind == .cookies
        ConfirmSheet.show(in: controller.root.overlay,
                          title: cookies ? String(localized: "Clear cookies for \(site)?", comment: "Title of the sheet that asks before clearing one site's cookies. The site is a domain, like example.com.")
                                         : String(localized: "Clear the cache for \(site)?", comment: "Title of the sheet that asks before clearing one site's cache. The site is a domain, like example.com."),
                          message: cookies ? String(localized: "You’ll be signed out of \(site). Other sites aren’t touched.", comment: "Message of the sheet that asks before clearing one site's cookies.")
                                           : String(localized: "It loads a little slower the first time. You stay signed in.", comment: "Message of the sheet that asks before clearing one site's cache."),
                          confirmTitle: cookies ? String(localized: "Clear Cookies", comment: "Button that clears cookies, in the sheet that asks first.")
                                                : String(localized: "Clear Cache", comment: "Button that clears the cache, in the sheet that asks first."), destructive: cookies) { [weak controller] confirmed in
            guard confirmed else { return }
            Self.clearNow(kind, site: site, tab: tab, controller: controller)
        }
    }

    private static func clearNow(_ kind: WebsiteData.Kind, site: String, tab: Tab, controller: BrowserWindowController?) {
        Task { @MainActor [weak controller] in
            await WebsiteData.clear(kind, site: site, in: tab.privateStore ?? tab.profile.store)
            tab.reload()
            if let controller { Toast.show(kind == .cache ? String(localized: "Cache cleared for \(site)", comment: "Toast after one site's cache is cleared. The site is a domain, like example.com.")
                                                       : String(localized: "Cookies cleared for \(site)", comment: "Toast after one site's cookies are cleared. The site is a domain, like example.com."),
                                        symbol: "checkmark.circle", in: controller) }
        }
    }

    // MARK: Layout

    private func layoutContent() {
        let height = layoutContent(dryRun: false)
        scroll.frame = bounds
        content.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(height, bounds.height))
        for box in [mainBox, permissionsBox, extensionsBox] { box.frame = content.bounds }
    }

    @discardableResult
    /// The site's name at its size, a little smaller when it's long, and past that cut the way the address cuts it,
    /// never clipped mid-letter.
    private static func fitted(_ name: String, in width: CGFloat) -> NSAttributedString {
        for size in stride(from: CGFloat(20), through: 15, by: -1) {
            let text = Tokens.Font.voiceText(name, size: size)
            if text.size().width <= width || size == 15 {
                guard text.size().width > width else { return text }
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineBreakMode = AddressView.lineBreak(forName: name)
                return Tokens.Font.voiceText(name, size: size, paragraph: paragraph)
            }
        }
        return Tokens.Font.voiceText(name, size: 20)
    }

    fileprivate func layoutContent(dryRun: Bool) -> CGFloat {
        func place(_ view: NSView, _ rect: NSRect) { if !dryRun { view.frame = rect } }
        // The certificate is a page of its own, laid out by itself.
        if page == .connection, let certificate = certificatePage {
            let h = certificate.height(for: width, pad: pad)
            place(certificate, NSRect(x: 0, y: 0, width: width, height: h))
            return h
        }
        let inner = width - pad * 2
        var y = pad
        // The room after the last thing placed, and the room under its words inside it: both are taken back at the
        // end, so the panel's bottom margin counts from the words, as its top does.
        var gapAfter: CGFloat = 0, slack: CGFloat = 0
        func end(_ gap: CGFloat, slack s: CGFloat = 0) { y += gap; gapAfter = gap; slack = s }
        func link(_ row: PanelLinkRow) {
            place(row, NSRect(x: pad - PanelLinkRow.outset, y: y, width: inner + PanelLinkRow.outset * 2, height: PanelLinkRow.height))
            y += PanelLinkRow.height
        }
        func finish() -> CGFloat { y - gapAfter - slack + pad }
        // A page's box covers the panel, so what's in it is placed in the panel's own terms.
        for box in [mainBox, permissionsBox, extensionsBox] where !box.isHidden { place(box, NSRect(x: 0, y: 0, width: width, height: 10_000)) }
        func pageHeader(_ header: PanelPageHeader) {
            place(header, NSRect(x: pad, y: y, width: inner, height: header.height))
            y += header.height
            end(Tokens.Space.x3)
        }
        func group(_ group: PanelGroup) {
            place(group, NSRect(x: pad, y: y, width: inner, height: group.height))
            y += group.height
        }

        switch page {
        case .permissions:
            pageHeader(permissionsHeader)
            group(permissionsGroup)
            if let resetPermissions {
                y += Tokens.Space.x2
                link(resetPermissions)
                end(0, slack: resetPermissions.bottomSlack)
            }
            return finish()
        case .extensions:
            pageHeader(extensionsHeader)
            if !extensionsSwitch.rows.isEmpty {
                group(extensionsSwitch)
                end(Tokens.Space.x4, slack: 0)
            }
            layoutExtensions(place: place, y: &y, inner: inner)
            if let manageExtensions {
                y += Tokens.Space.x2
                link(manageExtensions)
                end(0, slack: manageExtensions.bottomSlack)
            } else {
                end(0)
            }
            if !dryRun {
                for entry in hoverPins { entry.pin.frame = Self.pinFrame(on: entry.tile.frame, left: !entry.tile.badge.isEmpty) }
            }
            return finish()
        case .main, .connection:
            break
        }

        // Header: the site's icon and name, and ⋯.
        let iconSide = Tokens.Space.x6
        let moreSide = Tokens.Metric.iconButton
        let headerHeight = max(siteName.lineHeight, moreSide)
        let moreX = width - pad - moreSide + Tokens.Space.x1
        place(moreButton, NSRect(x: moreX, y: y + (headerHeight - moreSide) / 2, width: moreSide, height: moreSide))
        place(icon, NSRect(x: pad, y: y + (headerHeight - iconSide) / 2, width: iconSide, height: iconSide))
        let textX = pad + iconSide + Tokens.Space.x3
        let textWidth = (moreButton.isHidden ? width - pad : moreX) - textX
        siteName.attributedStringValue = Self.fitted(site, in: textWidth)
        place(siteName, NSRect(x: textX - Label.inset, y: y + (headerHeight - siteName.lineHeight) / 2, width: textWidth + Label.inset * 2, height: siteName.lineHeight))
        y += headerHeight
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

        // One line into each of the other pages, each saying what's there; only those that apply.
        var c = SitePanelRows.Context()
        c.isWeb = connectionRow != nil
        c.hasPermissions = permissionsRow?.isHidden == false
        c.extensionHost = extensionsRow != nil
        let links = SitePanelRows.links(c)
        let linkRows: [(SitePanelRows.Link, PanelLinkRow?)] = [(.connection, connectionRow), (.permissions, permissionsRow), (.extensions, extensionsRow)]
        var placed = false
        for (kind, row) in linkRows {
            guard let row else { continue }
            row.isHidden = !links.contains(kind)
            guard !row.isHidden else { continue }
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

    /// The extensions' grid on their page: the label (and whose they are), then the icons, or the + alone.
    private func layoutExtensions(place: (NSView, NSRect) -> Void, y: inout CGFloat, inner: CGFloat) {
        guard !extensionTiles.isEmpty else { return }
        let profile = Library.shared.hasManyProfiles && !tab.isPrivate ? Library.shared.directory.profile(tab.profile.id)?.displayName : nil
        extensionsProfileLabel.stringValue = profile ?? ""
        extensionsProfileLabel.isHidden = profile == nil
        // The page's title names them; with more than one profile, a quiet label says whose they are.
        if profile != nil {
            extensionsProfileLabel.alignment = .left
            place(extensionsProfileLabel, NSRect(x: pad - Label.inset, y: y, width: inner + Label.inset * 2, height: extensionsProfileLabel.lineHeight))
            y += extensionsProfileLabel.lineHeight + Tokens.Space.x2
        }
        if addsAlone, let add = extensionTiles.first {
            // Named, as the actions are: its icon over its name, as wide as the name shows whole.
            let w = max(add.captionWidth, PanelTile.captionedHeight)
            place(add, NSRect(x: pad, y: y, width: w, height: PanelTile.captionedHeight))
            y += PanelTile.captionedHeight
        } else {
            let columns = inner >= 260 ? 6 : inner >= 200 ? 5 : 4
            Self.grid(extensionTiles, columns: columns, gap: Tokens.Space.x2, centered: false, height: nil, x: pad, inner: inner, y: &y, place: place)
        }
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
    var isAttention = false
    var badge = "" {
        didSet {
            badgeView?.removeFromSuperview()
            badgeView = nil
            guard !badge.isEmpty else { return }
            // The same pill as on a pinned button in the address, in the tile's corner.
            let view = BadgeView(text: badge, attention: isAttention)
            view.inset = Self.badgeInset
            addSubview(view)
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
        let side: CGFloat = caption == nil ? Tokens.Space.x5 + 2 : Tokens.Space.x5
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

    override func stateDidChange(animated: Bool) {
        let accent = Brand.Theme.for(self).accent
        // No box: a thin line glyph over its small name, like a marking on a device. Only the pointer or a press
        // shows a soft wash behind it.
        let wash: NSColor? = isPressed ? Tokens.Color.pressedFill : isHovered ? Tokens.Color.hoverFill : nil
        layer?.set(backgroundColor: wash.map { cgColor($0) }, animated: false)
        layer?.borderWidth = 0
        setLifted(false)
        iconView.alphaValue = isEnabled ? 1 : Tokens.Opacity.disabled
        iconView.contentTintColor = isOn ? accent : Tokens.Color.icon
        caption?.alphaValue = isEnabled ? 1 : Tokens.Opacity.disabled
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
    var contentHeight: CGFloat { title.lineHeight + (value?.lineHeight ?? 0) }

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
        row.status = status
        toggle.onChange = { [weak row] on in
            row?.value?.stringValue = status(on)
            changed(on)
        }
        return row
    }

    /// What a toggle row's status says for each state.
    private var status: ((Bool) -> String)?

    /// A toggle row's switch moved by another row (Force dark turns Dark page on), without running its own change;
    /// what it says is read again either way.
    func setOn(_ on: Bool) {
        guard let toggle = control as? Toggle else { return }
        toggle.isOn = on
        if let status { value?.stringValue = status(on) }
    }

    /// A name and a dropdown of choices: a permission's Ask, Allow or Block.
    static func choice(_ title: String, options: [String], selected: Int, chose: @escaping (Int) -> Void) -> PanelRow {
        let dropdown = DropdownButton()
        dropdown.options = options.map { DropdownButton.Option(title: $0) }
        dropdown.selectedIndex = selected
        dropdown.onSelect = chose
        dropdown.setAccessibilityLabel(title)
        return PanelRow(title, control: dropdown)
    }

    /// A name and a control of the panel's own (the zoom stepper).
    static func custom(_ title: String, control: NSView) -> PanelRow { PanelRow(title, control: control) }

    #if DEBUG
    /// Its name, and what its dropdown or switch is set to.
    var debugTitle: String {
        if let dropdown = control as? DropdownButton { return "\(title.stringValue): \(dropdown.accessibilityValue() as? String ?? "")" }
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
        guard let value else {
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

/// The top of the panel: the site's icon and name, and under it whether the connection is private. On an https page
/// it's the way into the certificate, with a chevron at its end.
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

/// Which of the panel's rows apply to the page: none is shown that does nothing there.
enum SitePanelRows {
    /// This Site's switches, on the panel's first page.
    enum Row: Equatable { case zoom, adBlocking, cookieBanners, darkPage, forceDark, keepAwake, fullScreenFills, alwaysTranslate }
    /// The rows into the panel's other pages.
    enum Link: Equatable { case connection, permissions, extensions }

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
        /// The site looks dark on its own, or was forced dark already.
        var forceDarkOffered = false
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
    }

    static func rows(_ c: Context) -> [Row] {
        var rows: [Row] = []
        if c.isWeb, !c.coveredPage { rows.append(.zoom) }
        if c.isWeb, c.adBlocking, !c.isPrivate { rows.append(.adBlocking) }
        if c.isWeb, c.cookieBanners, !c.isPrivate { rows.append(.cookieBanners) }
        if c.siteChoices {
            rows.append(.darkPage)
            if c.forceDarkOffered { rows.append(.forceDark) }
            rows.append(.keepAwake)
        }
        if c.fullScreen { rows.append(.fullScreenFills) }
        if c.foreignLanguage { rows.append(.alwaysTranslate) }
        return rows
    }

    static func links(_ c: Context) -> [Link] {
        var links: [Link] = []
        if c.isWeb { links.append(.connection) }
        if c.hasPermissions { links.append(.permissions) }
        if c.extensionHost { links.append(.extensions) }
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
