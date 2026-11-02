import AppKit
import WebKit

/// Everything about the page you're on, behind one button by the address: the site, a row of quick actions, your
/// extensions in the same grid, and this site's own settings. Rarer things (copying the link, clearing the site's
/// cache or cookies) wait in the ⋯ menu. Changes apply at once and say so.
final class SitePanel: FloatingPanelView {
    private static weak var current: SitePanel?
    static var isOpen: Bool { current?.superview != nil }
    static func isOpen(in window: NSWindow?) -> Bool { isOpen && current?.window === window }
    /// The open panel, for debugging.
    static var shown: SitePanel? { current }
    static func closeCurrent() { current?.close() }

    private weak var controller: BrowserWindowController?
    private weak var anchor: NSView?
    private var monitor: Any?
    private let tab: Tab
    private let url: URL
    private let site: String
    private let isBlank: Bool
    /// The panel is about one page: when it goes to another site (a sign-in redirect), the panel goes too.
    private var pageToken: SignalToken?
    /// Whether this panel describes the page in this tab.
    func describes(_ other: Tab?) -> Bool { other === tab || other == nil && isBlank }

    private let icon = FaviconView()
    private let siteName = Label("", font: Tokens.Font.body(.semibold), color: Tokens.Color.textPrimary)
    private let security = Label("", font: Tokens.Font.small(), color: Tokens.Color.textSecondary)
    private let securityIcon = NSImageView()
    private let moreButton = IconButton(symbol: "ellipsis", toolTip: "More")
    private var actionTiles: [PanelTile] = []
    private let extensionsLabel = Label.section("Extensions")
    private var extensionTiles: [PanelTile] = []
    private let siteLabel = Label.section("This Site")
    private var rows: [PanelRow] = []
    private let group = PanelGroup()

    static let width: CGFloat = 300
    /// How a plain http page is marked, here and in the address bar: one symbol and one wording.
    static let notSecure = "Not secure"
    static let notSecureSymbol = "lock.open.fill"
    static let minimumWidth: CGFloat = 256
    private var width: CGFloat = SitePanel.width
    private var pad: CGFloat { width < Self.width ? Tokens.Space.x3 : Tokens.Space.x4 }

    private init?(controller: BrowserWindowController) {
        // With no page (a new tab), it still opens: your extensions are always one click away.
        let tab = controller.tabManager.selectedTab ?? Tab(url: nil, spaceID: controller.tabManager.currentSpaceID)
        let url = tab.url.flatMap { ["http", "https", "webkit-extension"].contains($0.scheme ?? "") ? $0 : nil }
        isBlank = url == nil
        self.controller = controller
        self.tab = tab
        self.url = url ?? URL(string: "about:blank")!
        site = url.map { ContentBlocker.site(of: $0) ?? $0.host() ?? $0.absoluteString } ?? "New Tab"
        super.init(frame: .zero)
        radius = Tokens.Radius.panel
        icon.image = tab.favicon
        siteName.stringValue = site
        let page = self.url
        let secure = page.scheme == "https" && (tab.webView?.hasOnlySecureContent ?? true)
        if page.scheme == "webkit-extension" {
            // An extension's own page never crosses the network: there's no connection to judge.
            security.stringValue = "Extension page"
            securityIcon.image = Tokens.Symbol.image("puzzlepiece.extension", size: Tokens.Symbol.inline)
            securityIcon.contentTintColor = Tokens.Color.textSecondary
        } else {
            security.stringValue = secure ? "Secure connection" : page.scheme == "https" ? "Some content isn’t secure" : Self.notSecure
            securityIcon.image = Tokens.Symbol.image(secure ? "lock" : Self.notSecureSymbol, size: Tokens.Symbol.inline)
            securityIcon.contentTintColor = secure ? Tokens.Color.textSecondary : Tokens.Color.warning
        }
        [icon, siteName, security, securityIcon, moreButton].forEach { addSubview($0) }
        let shownSite = site
        pageToken = tab.changed.observe { [weak self, weak tab] change in
            guard change == .url, let self, let now = tab?.url else { return }
            if (ContentBlocker.site(of: now) ?? now.host() ?? now.absoluteString) != shownSite { self.close() }
        }
        moreButton.onClick = { [weak self] _ in self?.showMoreMenu() }
        moreButton.isHidden = !canClear
        if isBlank {
            [security, securityIcon, moreButton].forEach { $0.isHidden = true }
            icon.image = Tokens.Symbol.image("plus.square.on.square", size: Tokens.Symbol.row)
        } else {
            buildTiles()
            buildRows()
        }
        buildExtensions()
        onLayout = { [weak self] in self?.layoutContent() }
        frame.size = NSSize(width: width, height: layoutContent(dryRun: true))
        setAccessibilityLabel("Site controls for \(site)")
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Showing

    static func toggle(in controller: BrowserWindowController, from anchor: NSView) {
        if let current, current.superview != nil { current.close(); return }
        guard let panel = SitePanel(controller: controller) else { return }
        controller.closeFloatingPanels()
        panel.anchor = anchor
        let anchorFrame = anchor.convert(anchor.bounds, to: controller.root.overlay)
        // From the address bar in the sidebar: its width and left edge, just below it. Anywhere else (sidebar
        // hidden) it keeps its own width.
        if anchor === controller.sidebar.address, controller.root.sidebarVisible, !controller.root.isSidebarFloatingVisible {
            // The same glass panel as Downloads over the sidebar's lane, with the tabs under it faded back.
            panel.width = anchorFrame.width
            panel.recedes = [controller.sidebar.list]
            panel.frame.size = NSSize(width: panel.width, height: panel.layoutContent(dryRun: true))
        }
        panel.frame.origin = NSPoint(x: max(Tokens.Metric.cardInset, anchorFrame.minX), y: anchorFrame.maxY + 4)
        controller.root.overlay.addSubview(panel)
        panel.needsLayout = true
        // Out of the button that opened it (the site controls, at the address's right end), not a corner.
        if let button = controller.sidebar.address.actionButtons.last, panel.frame.width > 0 {
            let b = button.convert(button.bounds, to: controller.root.overlay)
            panel.growsFrom = CGPoint(x: min(max((b.midX - panel.frame.minX) / panel.frame.width, 0), 1), y: 0)
        } else {
            panel.growsFrom = CGPoint(x: 0.5, y: 0)
        }
        panel.present(arrival: .pop)
        current = panel
        panel.monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak panel] event in
            // Only its own window: keys and clicks in Settings or another window are theirs. A menu open over it
            // takes Esc and the click that closes it.
            guard let panel, event.window === panel.window, MenuPanel.current == nil else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 { panel.close(); return nil }
                return event
            }
            let inside = panel.bounds.contains(panel.convert(event.locationInWindow, from: nil))
            let onAnchor = panel.anchor.map { $0.bounds.contains($0.convert(event.locationInWindow, from: nil)) } ?? false
            if !inside && !onAnchor { panel.close() }
            return event
        }
    }

    func close() {
        pageToken = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if Self.current === self { Self.current = nil }
        dismiss()
    }

    // MARK: Content

    /// What this page can do right now, as named tiles: sharing, the link and a screenshot always, Reader, Translate and
    /// Picture in Picture when the page has them. The steady ones come first, so they never move.
    private func buildTiles() {
        guard let controller else { return }
        let readerOn = controller.isShowingReader
        // (symbol, caption, full name for the tooltip and VoiceOver, on, action)
        var specs: [(String, String, String, Bool, () -> Void)] = []
        specs.append(("square.and.arrow.up", "Share", "Share", false, { [weak self] in self?.close(); self?.controller?.sharePage(nil) }))
        specs.append(("link", "Copy Link", "Copy Link", false, { [weak self] in
            guard let self else { return }
            self.controller?.copyLink(self.url)
            self.close()
        }))
        if PageScreenshot.canTake(tab), !readerOn {
            specs.append(("camera.viewfinder", "Capture", "Screenshot of the Whole Page", false, { [weak self] in
                guard let self, let controller = self.controller else { return }
                self.close()
                PageScreenshot.take(self.tab, in: controller)
            }))
        }
        if tab.isArticle || readerOn {
            specs.append(("doc.plaintext", "Reader", readerOn ? "Hide Reader" : "Reader", readerOn, { [weak self] in self?.controller?.toggleReader(); self?.close() }))
        }
        if tab.foreignLanguage != nil || tab.isTranslated {
            specs.append(("translate", tab.isTranslated ? "Original" : "Translate", tab.isTranslated ? "Show Original" : "Translate", tab.isTranslated, { [weak self] in self?.controller?.translatePage(); self?.close() }))
        }
        let floating = tab.webView?.isPictureInPictureActive ?? false
        if floating || tab.webView?.canTogglePictureInPicture ?? false {
            specs.append(("pip", "Float", floating ? "Back to Page" : "Picture in Picture", floating, { [weak self] in self?.controller?.togglePictureInPicture(nil); self?.close() }))
        }
        actionTiles = specs.map { symbol, caption, title, on, run in
            // The panel's own action words, lowercase like every button; the tooltip and VoiceOver keep the full name.
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
        MenuPanel.show([
            .item(.init(title: "Clear Cache for This Site…") { [weak self] in self?.clear(.cache) }),
            .item(.init(title: "Clear Cookies for This Site…") { [weak self] in self?.clear(.cookies) }),
        ], from: moreButton)
    }

    private func buildExtensions() {
        guard #available(macOS 15.4, *) else { return }
        let items = ExtensionHost.shared.actions(for: tab)
        extensionTiles = items.map { item in
            let tile = PanelTile(image: item.icon, symbol: "puzzlepiece.extension", caption: nil)
            tile.toolTip = item.attention != nil ? "\(item.label): needs attention" : item.label
            // VoiceOver reads the extension's name, then what its badge says.
            tile.setAccessibilityLabel(item.label)
            tile.setAccessibilityValue(item.attention != nil ? "Needs attention" : item.badge.isEmpty ? nil : item.badge)
            // Attention first: the badge takes its look from it.
            tile.isAttention = item.attention != nil
            tile.badge = item.attention != nil ? "!" : item.badge
            tile.onClick = { [weak self, weak tile] _ in
                guard let self, let tile else { return }
                ExtensionHost.shared.performAction(item, tab: self.tab, anchor: tile)
            }
            tile.onRightClick = { [weak self] _ in self?.controller?.extensionMenu(for: item.context) }
            addSubview(tile)
            return tile
        }
        let add = PanelTile(symbol: "plus", caption: nil)
        add.toolTip = "Get Extensions"
        add.setAccessibilityLabel("Get Extensions")
        add.onClick = { [weak self] _ in
            self?.controller?.tabManager.newTab(url: ExtensionStore.webStoreURL)
            self?.close()
        }
        addSubview(add)
        extensionTiles.append(add)
        addSubview(extensionsLabel)
    }

    private func buildRows() {
        rows = []
        if ContentBlocker.isEnabled {
            let blocked = !ContentBlocker.isAllowed(on: url)
            rows.append(.toggle("Ad blocking", on: blocked, status: { $0 ? "On for this site" : "Off for this site" }) { [weak self] on in
                guard let self else { return }
                ContentBlocker.setAllowed(!on, on: self.url)
                self.tab.reload()
            })
        }
        if #available(macOS 15.4, *), !ExtensionHost.shared.contexts.isEmpty {
            let off = ExtensionStore.extensionsOffSites.contains(site)
            rows.append(.toggle("Extensions", on: !off, status: { $0 ? "On for this site" : "Off for this site" }) { [weak self] on in
                guard let self else { return }
                var sites = ExtensionStore.extensionsOffSites
                if on { sites.remove(self.site) } else { sites.insert(self.site) }
                ExtensionStore.extensionsOffSites = sites
                self.tab.reload()
            })
        }
        if let language = tab.foreignLanguage {
            let name = PageTranslator.name(of: language)
            rows.append(.toggle(name, status: { $0 ? "Always translated" : "Translated when you ask" }, on: PageTranslator.translatesAlways(language)) { [weak self] on in
                PageTranslator.setTranslatesAlways(on, language)
                if on, self?.tab.isTranslated == false { self?.controller?.translatePage() }
            })
        }
        let host = url.host() ?? site
        // Calls (Meet, Zoom, Teams) ask for both at once and are kept as one answer; that counts here too.
        let media = [WKMediaCaptureType.camera, .microphone, .cameraAndMicrophone].compactMap { SitePermissions.decision(host: host, type: $0) }
        if !media.isEmpty {
            let allowed = media.allSatisfy { $0 }
            rows.append(.value("Camera and microphone", allowed ? "Allowed" : "Blocked", action: "Ask Again") { [weak self] in
                SitePermissions.forget(host: host)
                self?.rebuildRows()
            })
        }
        if let allowed = SitePermissions.location(host: host) {
            rows.append(.value("Location", allowed ? "Allowed" : "Blocked", action: "Ask Again") { [weak self] in
                SitePermissions.forgetLocation(host: host)
                self?.rebuildRows()
            })
        }
        if !tab.isPrivate, let allowed = SitePermissions.notifications(host: host.lowercased()) {
            rows.append(.toggle("Notifications", on: allowed, status: { $0 ? "Allowed" : "Blocked" }) { on in
                SitePermissions.setNotifications(on, host: host.lowercased())
                if !on { WebNotifications.shared.removeAll(host: host.lowercased()) }
            })
        }
        if !tab.isPrivate, SitePermissions.popups(host: host.lowercased()) {
            rows.append(.toggle("Pop-ups", on: true, status: { $0 ? "Allowed" : "Blocked" }) { on in
                SitePermissions.setPopups(on ? true : nil, host: host.lowercased())
            })
        }
        // The page's zoom as it is: in a private window that's its own, which isn't saved for the site.
        let zoom = tab.webView?.pageZoom ?? ZoomLevels.zoom(for: url)
        if abs(zoom - 1) > 0.001 {
            rows.append(.value("Zoom", "\(Int((zoom * 100).rounded()))%", action: "Reset") { [weak self] in
                guard let self else { return }
                if !self.tab.isPrivate { ZoomLevels.set(1, for: self.url) }
                self.tab.webView?.pageZoom = 1
                self.rebuildRows()
            })
        }
        if group.superview == nil { addSubview(group) }
        group.rows = rows
        group.isHidden = rows.isEmpty
        siteLabel.isHidden = rows.isEmpty
        if siteLabel.superview == nil { addSubview(siteLabel) }
    }

    private func rebuildRows() {
        buildRows()
        frame.size.height = layoutContent(dryRun: true)
        needsLayout = true
    }

    /// Asks first: cookies sign you out of the site, and neither can be taken back.
    private func clear(_ kind: WebsiteData.Kind) {
        let site = site, tab = tab
        close()
        guard let controller else { return }
        let cookies = kind == .cookies
        ConfirmSheet.show(in: controller.root.overlay,
                          title: cookies ? "Clear cookies for \(site)?" : "Clear the cache for \(site)?",
                          message: cookies ? "You’ll be signed out of \(site). Other sites aren’t touched." : "It loads a little slower the first time. You stay signed in.",
                          confirmTitle: cookies ? "Clear Cookies" : "Clear Cache", destructive: cookies) { [weak controller] confirmed in
            guard confirmed else { return }
            Self.clearNow(kind, site: site, tab: tab, controller: controller)
        }
    }

    private static func clearNow(_ kind: WebsiteData.Kind, site: String, tab: Tab, controller: BrowserWindowController?) {
        Task { @MainActor [weak controller] in
            await WebsiteData.clear(kind, site: site)
            tab.reload()
            if let controller { Toast.show(kind == .cache ? "Cache cleared for \(site)" : "Cookies cleared for \(site)", symbol: "checkmark.circle", in: controller) }
        }
    }

    // MARK: Layout

    private func layoutContent() { _ = layoutContent(dryRun: false) }

    @discardableResult
    fileprivate func layoutContent(dryRun: Bool) -> CGFloat {
        func place(_ view: NSView, _ rect: NSRect) { if !dryRun { view.frame = rect } }
        let inner = width - pad * 2
        var y = pad
        // Header: the site, whether the connection is private, and ⋯.
        let iconSide = Tokens.Space.x6
        let moreSide = Tokens.Metric.iconButton
        let headerHeight = siteName.lineHeight + security.lineHeight + 4
        place(moreButton, NSRect(x: width - pad - moreSide + Tokens.Space.x1, y: y + (headerHeight - moreSide) / 2, width: moreSide, height: moreSide))
        place(icon, NSRect(x: pad, y: y + (headerHeight - iconSide) / 2, width: iconSide, height: iconSide))
        let textX = pad + iconSide + Tokens.Space.x3
        let textWidth = width - textX - pad - moreSide
        place(siteName, NSRect(x: textX, y: y, width: textWidth, height: siteName.lineHeight))
        let lockSide: CGFloat = 10
        place(securityIcon, NSRect(x: textX, y: y + siteName.lineHeight + 3, width: lockSide, height: lockSide))
        place(security, NSRect(x: textX + lockSide + 4, y: y + siteName.lineHeight + 1, width: textWidth - lockSide - 4, height: security.lineHeight))
        y += headerHeight + Tokens.Space.x4

        // Actions are named tiles, as many to a row as fit; extensions are icons on the same rhythm below.
        var gap = Tokens.Space.x2
        func grid(_ tiles: [PanelTile], columns: Int, height: ((CGFloat) -> CGFloat)? = nil) {
            let side = floor((inner - gap * CGFloat(columns - 1)) / CGFloat(columns))
            let h = height?(side) ?? side
            for (i, tile) in tiles.enumerated() {
                let column = i % columns, row = i / columns
                place(tile, NSRect(x: pad + CGFloat(column) * (side + gap), y: y + CGFloat(row) * (h + gap), width: side, height: h))
            }
            y += CGFloat((tiles.count + columns - 1) / columns) * (h + gap) - gap
        }
        let columns = inner >= 260 ? 6 : inner >= 200 ? 5 : 4
        if !actionTiles.isEmpty {
            // One row, like the markings along a device's edge: every action side by side.
            let spacing = gap
            gap = 0
            grid(actionTiles, columns: actionTiles.count) { _ in PanelTile.captionedHeight }
            gap = spacing
            y += Tokens.Space.x5
        }
        if !extensionTiles.isEmpty {
            place(extensionsLabel, NSRect(x: pad, y: y, width: inner, height: extensionsLabel.lineHeight))
            y += extensionsLabel.lineHeight + Tokens.Space.x2
            grid(extensionTiles, columns: columns)
            y += Tokens.Space.x5
        }

        // This site's own settings.
        if !rows.isEmpty {
            place(siteLabel, NSRect(x: pad, y: y, width: inner, height: siteLabel.lineHeight))
            y += siteLabel.lineHeight + Tokens.Space.x2
            let h = group.height
            place(group, NSRect(x: pad, y: y, width: inner, height: h))
            y += h
        } else {
            y -= Tokens.Space.x5
        }
        return y + pad
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
            let view = BadgeView(text: badge, attention: isAttention)
            addSubview(view)
            badgeView = view
        }
    }

    /// How wide the tile must be for its name to show whole.
    var captionWidth: CGFloat { caption.map { ceil($0.textWidth) + Tokens.Space.x2 } ?? 0 }

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
        if let badgeView {
            let size = badgeView.fittingSize
            badgeView.frame = NSRect(x: bounds.width - size.width - 3, y: bounds.height - size.height - 3, width: size.width, height: size.height)
        }
    }

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

/// "This site"'s settings as one card, the way Settings groups its rows: a quiet fill, hairlines between that start
/// where the text does.
final class PanelGroup: NSView {
    var rows: [PanelRow] = [] {
        didSet {
            oldValue.forEach { $0.removeFromSuperview() }
            lines.forEach { $0.removeFromSuperview() }
            lines = rows.dropFirst().map { _ in ColorView(color: Tokens.Color.separator) }
            (rows + lines).forEach { addSubview($0) }
            needsLayout = true
        }
    }
    private var lines: [ColorView] = []
    private let fill = ColorView(color: Tokens.Color.fieldFill)

    var height: CGFloat { CGFloat(rows.count) * PanelRow.height }

    override init(frame: NSRect) {
        super.init(frame: frame)
        // Plain rows on the panel itself, no card behind them: space and a hairline between them are enough.
        fill.isHidden = true
        addSubview(fill)
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        fill.frame = bounds
        let inset: CGFloat = 0
        for (i, row) in rows.enumerated() {
            row.frame = NSRect(x: inset, y: CGFloat(i) * PanelRow.height, width: bounds.width - inset * 2, height: PanelRow.height)
        }
        for (i, line) in lines.enumerated() {
            let x = inset
            line.frame = NSRect(x: x, y: CGFloat(i + 1) * PanelRow.height, width: bounds.width - x, height: Tokens.Metric.hairline)
        }
    }
}

/// One line of "This site", as Settings draws its rows: a name with what it's set to under it, and a switch or a
/// pill button at the right. No symbols: the names say what each is.
final class PanelRow: NSView {
    static let height = Tokens.Page.groupRowHeight
    private let title: Label
    private let control: NSView
    private let value: Label?

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

    static func value(_ title: String, _ value: String, action: String, run: @escaping () -> Void) -> PanelRow {
        let button = PillButton(title: action)
        button.onClick = { _ in run() }
        return PanelRow(title, control: button, value: value)
    }

    override func layout() {
        super.layout()
        var size = control.fittingSize.width > 0 ? control.fittingSize : control.intrinsicContentSize
        if let pill = control as? PillButton { size = NSSize(width: pill.fittingWidth, height: Tokens.Page.controlHeight) }
        control.frame = NSRect(x: bounds.width - size.width, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
        let x = -Label.inset
        let right = control.frame.minX - Tokens.Space.x2 - x
        guard let value else {
            title.frame = NSRect(x: x, y: (bounds.height - title.lineHeight) / 2, width: right, height: title.lineHeight)
            return
        }
        let top = (bounds.height - title.lineHeight - value.lineHeight) / 2
        title.frame = NSRect(x: x, y: top, width: right, height: title.lineHeight)
        value.frame = NSRect(x: x, y: title.frame.maxY, width: right, height: value.lineHeight)
    }
}
