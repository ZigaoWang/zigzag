import AppKit
import WebKit

/// Everything about the page you're on, behind one button by the address: quick actions, your extensions, this
/// site's own settings, and clearing its cache or cookies. Changes apply at once and say so.
final class SitePanel: FloatingPanelView {
    private static weak var current: SitePanel?

    private weak var controller: BrowserWindowController?
    private weak var anchor: NSView?
    private var monitor: Any?
    private let tab: Tab
    private let url: URL
    private let site: String

    private let icon = FaviconView()
    private let siteName = Label("", font: Tokens.Font.body(.semibold), color: Tokens.Color.textPrimary)
    private let security = Label("", font: Tokens.Font.small(), color: Tokens.Color.textSecondary)
    private let securityIcon = NSImageView()
    private var tiles: [PanelTile] = []
    private let extensionsLabel = Label("Extensions", font: Tokens.Font.small(.semibold), color: Tokens.Color.textSecondary)
    private var extensionTiles: [PanelTile] = []
    private let siteLabel = Label("This site", font: Tokens.Font.small(.semibold), color: Tokens.Color.textSecondary)
    private var rows: [PanelRow] = []
    private let divider = ColorView(color: Tokens.Color.separator)
    private let clearCache = TextButton.form("Clear Cache")
    private let clearCookies = TextButton.form("Clear Cookies")

    static let width: CGFloat = 320
    private let pad = Tokens.Space.x4

    private init?(controller: BrowserWindowController) {
        guard let tab = controller.tabManager.selectedTab, let url = tab.url else { return nil }
        self.controller = controller
        self.tab = tab
        self.url = url
        site = ContentBlocker.site(of: url) ?? url.host() ?? url.absoluteString
        super.init(frame: .zero)
        radius = Tokens.Radius.panel + Tokens.Space.x1
        icon.image = tab.favicon
        siteName.stringValue = site
        let secure = url.scheme == "https" && (tab.webView?.hasOnlySecureContent ?? true)
        security.stringValue = url.scheme == "https" ? (secure ? "Secure connection" : "Some content isn’t secure") : (url.scheme == "http" ? "Not secure" : "")
        securityIcon.image = Tokens.Symbol.image(secure ? "lock.fill" : "lock.open.fill", size: Tokens.TypeSize.small)
        securityIcon.contentTintColor = secure ? Tokens.Color.textSecondary : Tokens.Color.warning
        [icon, siteName, security, securityIcon, divider, clearCache, clearCookies].forEach { addSubview($0) }
        buildTiles()
        buildExtensions()
        buildRows()
        clearCache.onClick = { [weak self] _ in self?.clear(.cache) }
        clearCookies.onClick = { [weak self] _ in self?.clear(.cookies) }
        if tab.isPrivate { [clearCache, clearCookies, divider].forEach { $0.isHidden = true } }
        onLayout = { [weak self] in self?.layoutContent() }
        frame.size = NSSize(width: Self.width, height: layoutContent(dryRun: true))
        setAccessibilityLabel("Site controls for \(site)")
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Showing

    static func toggle(in controller: BrowserWindowController, from anchor: NSView) {
        if let current, current.superview != nil { current.close(); return }
        guard let panel = SitePanel(controller: controller) else { return }
        panel.anchor = anchor
        let anchorFrame = anchor.convert(anchor.bounds, to: controller.root.overlay)
        panel.frame.origin = NSPoint(x: max(Tokens.Metric.cardInset, anchorFrame.minX), y: anchorFrame.maxY + Tokens.Space.x2)
        controller.root.overlay.addSubview(panel)
        panel.needsLayout = true
        panel.present()
        current = panel
        panel.monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak panel] event in
            guard let panel else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 { panel.close(); return nil }
                return event
            }
            guard event.window === panel.window else { return event }
            let inside = panel.bounds.contains(panel.convert(event.locationInWindow, from: nil))
            let onAnchor = panel.anchor.map { $0.bounds.contains($0.convert(event.locationInWindow, from: nil)) } ?? false
            if !inside && !onAnchor { panel.close() }
            return event
        }
    }

    func close() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if Self.current === self { Self.current = nil }
        dismiss()
    }

    // MARK: Content

    private func buildTiles() {
        guard let controller else { return }
        let readerOn = controller.isShowingReader
        let canPiP = tab.webView?.canTogglePictureInPicture ?? false
        let canTranslate = tab.foreignLanguage != nil || tab.isTranslated
        let specs: [(String, String, Bool, Bool, () -> Void)] = [
            ("link", "Copy Link", true, false, { [weak self] in
                guard let self else { return }
                self.controller?.copyLink(self.url)
                self.close()
            }),
            ("doc.plaintext", readerOn ? "Close Reader" : "Reader", tab.isArticle || readerOn, readerOn, { [weak self] in
                self?.controller?.toggleReader()
                self?.close()
            }),
            ("pip", "Picture in Picture", canPiP, false, { [weak self] in
                self?.controller?.togglePictureInPicture(nil)
                self?.close()
            }),
            ("translate", tab.isTranslated ? "Show Original" : "Translate", canTranslate, tab.isTranslated, { [weak self] in
                self?.controller?.translatePage()
                self?.close()
            }),
        ]
        tiles = specs.map { symbol, title, enabled, on, run in
            let tile = PanelTile(symbol: symbol, caption: title)
            tile.isEnabled = enabled
            tile.isOn = on
            tile.toolTip = enabled ? title : unavailable(title)
            tile.onClick = { _ in if enabled { run() } }
            addSubview(tile)
            return tile
        }
    }

    private func unavailable(_ title: String) -> String {
        switch title {
        case "Reader": "This page doesn’t have an article to read"
        case "Picture in Picture": "No video playing on this page"
        default: "This page is already in your language"
        }
    }

    private func buildExtensions() {
        guard #available(macOS 15.4, *) else { return }
        let items = ExtensionHost.shared.actions(for: tab)
        extensionTiles = items.map { item in
            let tile = PanelTile(image: item.icon, symbol: "puzzlepiece.extension", caption: nil)
            tile.toolTip = item.attention != nil ? "\(item.label): needs attention" : item.label
            tile.badge = item.attention != nil ? "!" : item.badge
            tile.isAttention = item.attention != nil
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
        let host = url.host() ?? site
        let camera = SitePermissions.decision(host: host, type: .camera), microphone = SitePermissions.decision(host: host, type: .microphone)
        if camera != nil || microphone != nil {
            let allowed = [camera, microphone].compactMap { $0 }.allSatisfy { $0 }
            rows.append(.value("Camera and microphone", allowed ? "Allowed" : "Blocked", action: "Ask Again") { [weak self] in
                SitePermissions.forget(host: host)
                self?.rebuildRows()
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
        let button = kind == .cache ? clearCache : clearCookies
        Task { @MainActor in
            await WebsiteData.clear(kind, site: site)
            tab.reload()
            button.flash(kind == .cache ? "Cache Cleared" : "Cookies Cleared")
        }
    }

    // MARK: Layout

    private func layoutContent() { _ = layoutContent(dryRun: false) }

    @discardableResult
    private func layoutContent(dryRun: Bool) -> CGFloat {
        func place(_ view: NSView, _ rect: NSRect) { if !dryRun { view.frame = rect } }
        let inner = Self.width - pad * 2
        var y = pad
        // Header: the site, and whether the connection is private.
        let iconSide = Tokens.Space.x6
        place(icon, NSRect(x: pad, y: y + 2, width: iconSide, height: iconSide))
        let textX = pad + iconSide + Tokens.Space.x3
        place(siteName, NSRect(x: textX, y: y, width: inner - (textX - pad), height: siteName.lineHeight))
        let lockSide: CGFloat = 11
        place(securityIcon, NSRect(x: textX, y: y + siteName.lineHeight + 3, width: lockSide, height: lockSide))
        place(security, NSRect(x: textX + lockSide + 4, y: y + siteName.lineHeight + 1, width: inner, height: security.lineHeight))
        y += max(iconSide + 4, siteName.lineHeight + security.lineHeight + 2) + Tokens.Space.x4

        // Quick actions.
        let gap = Tokens.Space.x2
        let tileWidth = (inner - gap * CGFloat(tiles.count - 1)) / CGFloat(tiles.count)
        let tileHeight: CGFloat = 62
        for (i, tile) in tiles.enumerated() {
            place(tile, NSRect(x: pad + CGFloat(i) * (tileWidth + gap), y: y, width: tileWidth, height: tileHeight))
        }
        y += tileHeight + Tokens.Space.x5

        // Extensions: a grid, with Get Extensions at the end.
        if !extensionTiles.isEmpty {
            place(extensionsLabel, NSRect(x: pad, y: y, width: inner, height: extensionsLabel.lineHeight))
            y += extensionsLabel.lineHeight + Tokens.Space.x2
            let columns = 6
            let side = (inner - gap * CGFloat(columns - 1)) / CGFloat(columns)
            for (i, tile) in extensionTiles.enumerated() {
                let column = i % columns, row = i / columns
                place(tile, NSRect(x: pad + CGFloat(column) * (side + gap), y: y + CGFloat(row) * (side + gap), width: side, height: side))
            }
            let rowsCount = (extensionTiles.count + columns - 1) / columns
            y += CGFloat(rowsCount) * (side + gap) - gap + Tokens.Space.x5
        }

        // This site's own settings.
        if !rows.isEmpty {
            place(siteLabel, NSRect(x: pad, y: y, width: inner, height: siteLabel.lineHeight))
            y += siteLabel.lineHeight + Tokens.Space.x1
            for row in rows {
                place(row, NSRect(x: pad, y: y, width: inner, height: PanelRow.height))
                y += PanelRow.height
            }
            y += Tokens.Space.x3
        }

        // Clearing, for this site only.
        if !clearCache.isHidden {
            place(divider, NSRect(x: pad, y: y, width: inner, height: Tokens.Metric.hairline))
            y += Tokens.Space.x3
            let half = (inner - gap) / 2
            place(clearCache, NSRect(x: pad, y: y, width: half, height: Tokens.Space.x8))
            place(clearCookies, NSRect(x: pad + half + gap, y: y, width: half, height: Tokens.Space.x8))
            y += Tokens.Space.x8
        }
        return y + pad
    }
}

/// A square action in the site panel: a symbol (or an extension's icon), an optional caption, and states for
/// hover, on (in the space's accent), unavailable, and a badge.
final class PanelTile: InteractiveView {
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
        let side: CGFloat = caption == nil ? min(bounds.width, bounds.height) * 0.46 : 20
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
        let fill: NSColor = isOn ? accent.withAlphaComponent(isPressed ? 0.26 : 0.18)
            : !isEnabled ? Tokens.Color.fieldFill.withAlphaComponent(0.5)
            : isPressed ? Tokens.Color.pressedFill : isHovered ? Tokens.Color.highlight : Tokens.Color.fieldFill
        layer?.set(backgroundColor: cgColor(fill), animated: animated && !isHovered)
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
    private var handler: SidebarMenus.Handler?

    private init(_ title: String, control: NSView, value: String? = nil) {
        self.title = Label(title, font: Tokens.Font.body(), color: Tokens.Color.textPrimary)
        self.control = control
        self.value = value.map { Label($0, font: Tokens.Font.body(), color: Tokens.Color.textSecondary) }
        super.init(frame: .zero)
        [self.title, control].forEach { addSubview($0) }
        if let label = self.value { addSubview(label) }
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    static func toggle(_ title: String, on: Bool, changed: @escaping (Bool) -> Void) -> PanelRow {
        let toggle = NSSwitch()
        toggle.controlSize = .small
        toggle.state = on ? .on : .off
        let row = PanelRow(title, control: toggle)
        let handler = SidebarMenus.Handler { [weak toggle] in changed(toggle?.state == .on) }
        toggle.target = handler
        toggle.action = #selector(SidebarMenus.Handler.runAction(_:))
        row.handler = handler
        return row
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
        var right = control.frame.minX - Tokens.Space.x2
        if let value {
            let w = value.textWidth
            value.frame = NSRect(x: right - w, y: (bounds.height - value.lineHeight) / 2, width: w, height: value.lineHeight)
            right = value.frame.minX - Tokens.Space.x2
        }
        title.frame = NSRect(x: 0, y: (bounds.height - title.lineHeight) / 2, width: right, height: title.lineHeight)
    }
}
