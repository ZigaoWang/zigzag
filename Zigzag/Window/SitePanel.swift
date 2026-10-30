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
    private let moreButton = IconButton(symbol: "ellipsis", size: Tokens.Space.x7Height, toolTip: "More")
    private var actionTiles: [PanelTile] = []
    private let extensionsLabel = Label("Extensions", font: Tokens.Font.small(.semibold), color: Tokens.Color.textSecondary)
    private var extensionTiles: [PanelTile] = []
    private let siteLabel = Label("This site", font: Tokens.Font.small(.semibold), color: Tokens.Color.textSecondary)
    private var rows: [PanelRow] = []

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
            securityIcon.image = Tokens.Symbol.image("puzzlepiece.extension", size: Tokens.TypeSize.small)
            securityIcon.contentTintColor = Tokens.Color.textSecondary
        } else {
            security.stringValue = secure ? "Secure connection" : page.scheme == "https" ? "Some content isn’t secure" : Self.notSecure
            securityIcon.image = Tokens.Symbol.image(secure ? "lock.fill" : Self.notSecureSymbol, size: Tokens.TypeSize.small)
            securityIcon.contentTintColor = secure ? Tokens.Color.textSecondary : Tokens.Color.warning
        }
        [icon, siteName, security, securityIcon, moreButton].forEach { addSubview($0) }
        let shownSite = site
        pageToken = tab.changed.observe { [weak self, weak tab] change in
            guard change == .url, let self, let now = tab?.url else { return }
            if (ContentBlocker.site(of: now) ?? now.host() ?? now.absoluteString) != shownSite { self.close() }
        }
        moreButton.onClick = { [weak self] _ in self?.showMoreMenu() }
        if isBlank {
            [security, securityIcon, moreButton].forEach { $0.isHidden = true }
            icon.image = Tokens.Symbol.image("plus.square.on.square", size: 16)
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
        // From the address bar in the sidebar: its width and left edge, just below it, in the space's tint, so it
        // reads as part of the sidebar. Anywhere else (sidebar hidden) it keeps its own width.
        if anchor === controller.sidebar.address, controller.root.sidebarVisible, !controller.root.isSidebarFloatingVisible {
            // Part of the sidebar, not a card over it: the address bar's own width, flat (no shadow), in the
            // sidebar's colour a shade lighter, like the address field itself.
            panel.width = anchorFrame.width
            panel.surfaceTint = controller.tabManager.isPrivate ? SpaceColor.graphite.background : controller.tabManager.currentSpace.background
            panel.tintStrength = 0.82
            panel.isElevated = false
            panel.radius = controller.sidebar.address.layer?.cornerRadius ?? Tokens.Radius.panel
            panel.frame.size = NSSize(width: panel.width, height: panel.layoutContent(dryRun: true))
        }
        panel.frame.origin = NSPoint(x: max(Tokens.Metric.cardInset, anchorFrame.minX), y: anchorFrame.maxY + 4)
        controller.root.overlay.addSubview(panel)
        panel.needsLayout = true
        panel.growsFrom = CGPoint(x: 0.2, y: 0)
        panel.present(arrival: .pop)
        current = panel
        panel.monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak panel] event in
            // Only its own window: keys and clicks in Settings or another window are theirs.
            guard let panel, event.window === panel.window else { return event }
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

    /// What this page can do right now, as a row of icons: sharing and a screenshot always, Reader, Translate and
    /// Picture in Picture when the page has them. The steady ones come first, so they never move.
    private func buildTiles() {
        guard let controller else { return }
        let readerOn = controller.isShowingReader
        var specs: [(String, String, Bool, () -> Void)] = []
        specs.append(("square.and.arrow.up", "Share", false, { [weak self] in self?.close(); self?.controller?.sharePage(nil) }))
        if PageScreenshot.canTake(tab), !readerOn {
            specs.append(("camera.viewfinder", "Screenshot of the Whole Page", false, { [weak self] in
                guard let self, let controller = self.controller else { return }
                self.close()
                PageScreenshot.take(self.tab, in: controller)
            }))
        }
        if tab.isArticle || readerOn {
            specs.append(("doc.plaintext", readerOn ? "Close Reader" : "Reader", readerOn, { [weak self] in self?.controller?.toggleReader(); self?.close() }))
        }
        if tab.foreignLanguage != nil || tab.isTranslated {
            specs.append(("translate", tab.isTranslated ? "Show Original" : "Translate", tab.isTranslated, { [weak self] in self?.controller?.translatePage(); self?.close() }))
        }
        let floating = tab.webView?.isPictureInPictureActive ?? false
        if floating || tab.webView?.canTogglePictureInPicture ?? false {
            specs.append(("pip", floating ? "Back to Page" : "Picture in Picture", floating, { [weak self] in self?.controller?.togglePictureInPicture(nil); self?.close() }))
        }
        actionTiles = specs.map { symbol, title, on, run in
            let tile = PanelTile(symbol: symbol, caption: nil)
            tile.toolTip = title
            tile.setAccessibilityLabel(title)
            tile.isOn = on
            tile.onClick = { _ in run() }
            addSubview(tile)
            return tile
        }
    }

    /// Copy Link, and clearing this site's cache or cookies: there when you need them, out of the way when you don't.
    private func showMoreMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(SidebarMenus.Item("Copy Link") { [weak self] in
            guard let self else { return }
            self.controller?.copyLink(self.url)
            self.close()
        })
        // Only a web site has a cache and cookies of its own to clear: not a file, an extension's page or a new tab.
        if !tab.isPrivate, url.scheme == "http" || url.scheme == "https" {
            menu.addItem(.separator())
            menu.addItem(SidebarMenus.Item("Clear Cache for This Site") { [weak self] in self?.clear(.cache) })
            menu.addItem(SidebarMenus.Item("Clear Cookies for This Site") { [weak self] in self?.clear(.cookies) })
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: moreButton.isFlipped ? moreButton.bounds.maxY + 4 : -4), in: moreButton)
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
        rows.forEach { $0.removeFromSuperview() }
        rows = []
        if ContentBlocker.isEnabled {
            let blocked = !ContentBlocker.isAllowed(on: url)
            rows.append(.toggle("Block ads and trackers", on: blocked) { [weak self] on in
                guard let self else { return }
                ContentBlocker.setAllowed(!on, on: self.url)
                self.tab.reload()
            })
        }
        if #available(macOS 15.4, *), !ExtensionHost.shared.contexts.isEmpty {
            let off = ExtensionStore.extensionsOffSites.contains(site)
            rows.append(.toggle("Extensions on this site", on: !off) { [weak self] on in
                guard let self else { return }
                var sites = ExtensionStore.extensionsOffSites
                if on { sites.remove(self.site) } else { sites.insert(self.site) }
                ExtensionStore.extensionsOffSites = sites
                self.tab.reload()
            })
        }
        if let language = tab.foreignLanguage {
            let name = PageTranslator.name(of: language)
            rows.append(.toggle("Always translate \(name)", on: PageTranslator.translatesAlways(language)) { [weak self] on in
                PageTranslator.setTranslatesAlways(on, language)
                if on, self?.tab.isTranslated == false { self?.controller?.translatePage() }
            })
        }
        let host = url.host() ?? site
        let camera = SitePermissions.decision(host: host, type: .camera), microphone = SitePermissions.decision(host: host, type: .microphone)
        if camera != nil || microphone != nil {
            let allowed = [camera, microphone].compactMap { $0 }.allSatisfy { $0 }
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
            rows.append(.toggle("Notifications", on: allowed) { on in
                SitePermissions.setNotifications(on, host: host.lowercased())
                if !on { WebNotifications.shared.removeAll(host: host.lowercased()) }
            })
        }
        let zoom = ZoomLevels.zoom(for: url)
        if abs(zoom - 1) > 0.001 {
            rows.append(.value("Zoom", "\(Int((zoom * 100).rounded()))%", action: "Reset") { [weak self] in
                guard let self else { return }
                ZoomLevels.set(1, for: self.url)
                self.tab.webView?.pageZoom = 1
                self.rebuildRows()
            })
        }
        rows.forEach { addSubview($0) }
        siteLabel.isHidden = rows.isEmpty
        if siteLabel.superview == nil { addSubview(siteLabel) }
    }

    private func rebuildRows() {
        buildRows()
        frame.size.height = layoutContent(dryRun: true)
        needsLayout = true
    }

    private func clear(_ kind: WebsiteData.Kind) {
        let site = site, tab = tab
        close()
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
        let moreSide = Tokens.Space.x7Height
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

        // Actions and extensions share one grid: the same tiles, the same size, lined up with each other.
        let gap: CGFloat = 6, columns = inner >= 260 ? 6 : inner >= 200 ? 5 : 4
        let side = floor((inner - gap * CGFloat(columns - 1)) / CGFloat(columns))
        func grid(_ tiles: [PanelTile]) {
            for (i, tile) in tiles.enumerated() {
                let column = i % columns, row = i / columns
                place(tile, NSRect(x: pad + CGFloat(column) * (side + gap), y: y + CGFloat(row) * (side + gap), width: side, height: side))
            }
            y += CGFloat((tiles.count + columns - 1) / columns) * (side + gap) - gap
        }
        if !actionTiles.isEmpty {
            grid(actionTiles)
            y += Tokens.Space.x5
        }
        if !extensionTiles.isEmpty {
            place(extensionsLabel, NSRect(x: pad, y: y, width: inner, height: extensionsLabel.lineHeight))
            y += extensionsLabel.lineHeight + Tokens.Space.x2
            grid(extensionTiles)
            y += Tokens.Space.x5
        }

        // This site's own settings.
        if !rows.isEmpty {
            place(siteLabel, NSRect(x: pad, y: y, width: inner, height: siteLabel.lineHeight))
            y += siteLabel.lineHeight
            for row in rows {
                place(row, NSRect(x: pad, y: y, width: inner, height: PanelRow.height))
                y += PanelRow.height
            }
        } else {
            y -= Tokens.Space.x5
        }
        return y + pad
    }
}

/// A small action with its name: a symbol and a word on a quiet pill. On (Reader open) takes the space's accent.
final class ActionChip: InteractiveView {
    private let icon = NSImageView()
    private let label: Label
    var isOn = false { didSet { stateDidChange(animated: false) } }

    init(symbol: String, title: String) {
        label = Label(title, font: Tokens.Font.body(.medium), color: Tokens.Color.textPrimary)
        super.init(frame: .zero)
        layer?.cornerRadius = Tokens.Radius.control + 2
        layer?.cornerCurve = .continuous
        icon.image = Tokens.Symbol.image(symbol, size: Tokens.TypeSize.body)
        [icon, label].forEach { addSubview($0) }
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        stateDidChange(animated: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    var fittingWidth: CGFloat { ceil(Tokens.Space.x2 + 2 + 16 + Tokens.Space.x1 + 2 + label.inkWidth + Tokens.Space.x3) }

    override func layout() {
        super.layout()
        icon.frame = NSRect(x: Tokens.Space.x2 + 2, y: (bounds.height - 16) / 2, width: 16, height: 16)
        label.frame = NSRect(x: icon.frame.maxX + Tokens.Space.x1 + 2 - Label.inset, y: (bounds.height - label.lineHeight) / 2,
                             width: label.inkWidth + Label.inset * 2, height: label.lineHeight)
    }

    override func stateDidChange(animated: Bool) {
        let accent = Tokens.Color.accent
        let fill = isOn ? accent.withAlphaComponent(isPressed ? 0.26 : 0.16) : isPressed ? Tokens.Color.pressedFill : isHovered ? Tokens.Color.highlight : Tokens.Color.fieldFill
        layer?.set(backgroundColor: cgColor(fill), animated: animated && !isHovered)
        icon.contentTintColor = isOn ? accent : Tokens.Color.icon
    }
}

/// A square action in the site panel: a symbol (or an extension's icon), an optional caption, and states for
/// hover, on (in the space's accent), unavailable, and a badge.
final class PanelTile: InteractiveView {
    private let iconView = NSImageView()
    private let caption: Label?
    private var badgeView: BadgeView?
    var isOn = false { didSet { stateDidChange(animated: false) } }
    /// No fill until hovered, for rows of icons.
    var restsPlain = false { didSet { stateDidChange(animated: false) } }
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

    init(image: NSImage? = nil, symbol: String, caption text: String?) {
        caption = text.map { Label($0, font: Tokens.Font.small(.medium), color: Tokens.Color.textSecondary) }
        super.init(frame: .zero)
        layer?.cornerRadius = Tokens.Radius.panel - 2
        layer?.cornerCurve = .continuous
        iconView.image = image ?? Tokens.Symbol.image(symbol, size: text == nil ? Tokens.TypeSize.body : 17)
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
        let side: CGFloat = caption == nil ? 22 : 20
        if let caption {
            let total = side + Tokens.Space.x1 + caption.lineHeight
            let top = (bounds.height - total) / 2
            iconView.frame = NSRect(x: (bounds.width - side) / 2, y: bounds.height - top - side, width: side, height: side)
            caption.frame = NSRect(x: 2, y: top, width: bounds.width - 4, height: caption.lineHeight)
        } else {
            iconView.frame = NSRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
        }
        if let badgeView {
            let size = badgeView.fittingSize
            badgeView.frame = NSRect(x: bounds.width - size.width - 3, y: bounds.height - size.height - 3, width: size.width, height: size.height)
        }
    }

    override func stateDidChange(animated: Bool) {
        let accent = Tokens.Color.accent
        let rest: NSColor? = restsPlain ? nil : Tokens.Color.fieldFill
        let fill: NSColor? = isOn ? accent.withAlphaComponent(isPressed ? 0.26 : 0.18)
            : isPressed ? Tokens.Color.pressedFill : isHovered ? (restsPlain ? Tokens.Color.hoverFill : Tokens.Color.highlight) : rest
        layer?.set(backgroundColor: fill.map { cgColor($0) }, animated: animated && !isHovered)
        iconView.alphaValue = isEnabled ? 1 : Tokens.Opacity.disabled
        iconView.contentTintColor = isOn ? accent : Tokens.Color.icon
        caption?.alphaValue = isEnabled ? 1 : Tokens.Opacity.disabled
        caption?.textColor = isOn ? Tokens.Color.textPrimary : Tokens.Color.textSecondary
    }
}

/// One line of "This site": a name and a switch, or a name, its value and a small action.
final class PanelRow: NSView {
    static let height: CGFloat = 34
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

    static func toggle(_ title: String, on: Bool, changed: @escaping (Bool) -> Void) -> PanelRow {
        let toggle = Toggle(isOn: on)
        toggle.onChange = changed
        return PanelRow(title, control: toggle)
    }

    static func value(_ title: String, _ value: String, action: String, run: @escaping () -> Void) -> PanelRow {
        let button = TextButton(title: action, font: Tokens.Font.body(.medium))
        button.onClick = { _ in run() }
        return PanelRow(title, control: button, value: value)
    }

    override func layout() {
        super.layout()
        let size = control.fittingSize.width > 0 ? control.fittingSize : control.intrinsicContentSize
        control.frame = NSRect(x: bounds.width - size.width, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
        let right = control.frame.minX - Tokens.Space.x2
        guard let value else {
            title.frame = NSRect(x: 0, y: (bounds.height - title.lineHeight) / 2, width: right, height: title.lineHeight)
            return
        }
        let top = (bounds.height - title.lineHeight - value.lineHeight) / 2
        title.frame = NSRect(x: 0, y: top, width: right, height: title.lineHeight)
        value.frame = NSRect(x: 0, y: title.frame.maxY, width: right, height: value.lineHeight)
    }
}
