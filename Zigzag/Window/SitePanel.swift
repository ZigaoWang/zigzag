import AppKit
import WebKit

/// Everything about the page you're on, behind one button by the address: the site, a row of quick actions, your
/// extensions in the same grid, and this site's own settings. Rarer things (copying the link, clearing the site's
/// cache or cookies) wait in the ⋯ menu. Changes apply at once and say so.
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

    private let icon = FaviconView()
    private let siteName = Label("", font: Tokens.Font.voice(20), color: Tokens.Color.textPrimary)
    private let security = Label("", font: Tokens.Font.small(), color: Tokens.Color.textSecondary)
    private let securityIcon = NSImageView()
    private let moreButton = IconButton(symbol: "ellipsis", toolTip: String(localized: "More", comment: "Tooltip of the … button in the site panel."))
    private var actionTiles: [PanelTile] = []
    private let extensionsLabel = Label.section(String(localized: "Extensions", comment: "Section label over the extensions' buttons in the site panel."))
    private var extensionTiles: [PanelTile] = []
    /// The pin button on each extension's tile: the panel's child over the tile, a control of its own.
    private var hoverPins: [(id: String, label: String, value: String?, tile: PanelTile, pin: HoverPin)] = []
    private var extensionsToken: SignalToken?
    private let siteLabel = Label.section(String(localized: "This Site", comment: "Section label over the site's settings in the site panel."))
    private var rows: [PanelRow] = []
    private let group = PanelGroup()

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

    private init?(controller: BrowserWindowController) {
        // With no page (a new tab), it still opens: your extensions are always one click away.
        let tab = controller.tabManager.selectedTab ?? Tab(url: nil, spaceID: controller.tabManager.currentSpaceID)
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
        radius = Tokens.Radius.panel
        icon.image = tab.favicon
        // In the app's voice, as a page names itself; a site's name keeps its own spelling. Plain http or a port of
        // its own is named in full, as its answers are its own: localhost:3000 never reads like localhost:3001.
        let web = ["http", "https"].contains(url?.scheme?.lowercased() ?? "")
        let full = origin.map(SiteOrigin.label).flatMap { $0.contains(":") ? $0 : nil }
        let named = web ? full ?? site : site
        siteName.attributedStringValue = Tokens.Font.voiceText(named, size: 20)
        let page = self.url
        let secure = page.scheme == "https" && (tab.webView?.hasOnlySecureContent ?? true)
        if page.scheme == "webkit-extension" {
            // An extension's own page never crosses the network: there's no connection to judge.
            security.stringValue = String(localized: "Extension page", comment: "Under the site's name in the site panel, for an extension's own page.")
            securityIcon.image = Tokens.Symbol.image("puzzlepiece.extension", size: Tokens.Symbol.inline)
            securityIcon.contentTintColor = Tokens.Color.textSecondary
        } else {
            security.stringValue = secure ? String(localized: "Secure connection", comment: "Under the site's name in the site panel, for a page loaded over https.")
                : page.scheme == "https" ? String(localized: "Some content isn’t secure", comment: "Under the site's name in the site panel, for an https page with some parts loaded over plain http.")
                : Self.notSecure
            securityIcon.image = Tokens.Symbol.image(secure ? "lock" : Self.notSecureSymbol, size: Tokens.Symbol.inline)
            securityIcon.contentTintColor = secure ? Tokens.Color.textSecondary : Tokens.Color.warning
        }
        [icon, siteName, security, securityIcon, moreButton].forEach { addSubview($0) }
        let shownSite = site
        pageToken = tab.changed.observe { [weak self, weak tab] change in
            guard change == .url, let self, let now = tab?.url else { return }
            if (ContentBlocker.site(of: now) ?? now.host() ?? now.absoluteString) != shownSite || SiteOrigin.of(now) != origin { self.close() }
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
        setAccessibilityLabel(String(localized: "Site controls for \(site)", comment: "VoiceOver name of the site panel. The site is a domain, like example.com."))
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Showing

    static func toggle(in controller: BrowserWindowController, from anchor: NSView) {
        if let current, current.superview != nil { current.close(); return }
        guard let panel = SitePanel(controller: controller) else { return }
        controller.closeFloatingPanels()
        panel.anchor = anchor
        let anchorFrame = anchor.convert(anchor.bounds, to: controller.root.overlay)
        // From the address bar in the sidebar: its width and left edge, just below it. With the sidebar slid out or
        // hidden it's the same width (the address keeps its width off screen), so it never grows past the sidebar.
        // From the address above the page, the sidebar's width, under the address's end where its button is.
        let aboveThePage = anchor.isDescendant(of: controller.root.topBar)
        let sidebarLane = controller.root.sidebarWidth - Tokens.Metric.sidebarPadding * 2
        panel.width = anchorFrame.width > 0 && !aboveThePage ? anchorFrame.width : sidebarLane
        if controller.root.sidebarVisible, !controller.root.isSidebarFloatingVisible, !aboveThePage {
            // The same glass panel as Downloads over the sidebar's lane, with the tabs under it faded back.
            panel.recedes = [controller.sidebar.list]
        }
        panel.frame.size = NSSize(width: panel.width, height: panel.layoutContent(dryRun: true))
        let x = aboveThePage ? anchorFrame.maxX - panel.width : anchorFrame.minX
        panel.frame.origin = NSPoint(x: max(Tokens.Metric.cardInset, x), y: anchorFrame.maxY + 4)
        controller.root.overlay.addSubview(panel)
        panel.needsLayout = true
        // Out of the button that opened it (the site controls, at the address's right end), not a corner.
        if panel.frame.width > 0 {
            let button = controller.sidebar.address.siteControlsButton
            let b = button.convert(button.bounds, to: controller.root.overlay)
            panel.growsFrom = CGPoint(x: min(max((b.midX - panel.frame.minX) / panel.frame.width, 0), 1), y: 0)
        } else {
            panel.growsFrom = CGPoint(x: 0.5, y: 0)
        }
        panel.present(arrival: .pop)
        controller.sidebar.address.siteControlsButton.isSelected = true
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
        extensionsToken = nil
        controller?.sidebar.address.siteControlsButton.isSelected = false
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
        MenuPanel.show([
            .item(.init(title: String(localized: "Clear Cache for This Site…", comment: "Item in the … menu of the site panel.")) { [weak self] in self?.clear(.cache) }),
            .item(.init(title: String(localized: "Clear Cookies for This Site…", comment: "Item in the … menu of the site panel.")) { [weak self] in self?.clear(.cookies) }),
        ], from: moreButton)
    }

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
            addSubview(tile)
            hoverPins.append((item.id, item.label, value, tile, HoverPin()))
            return tile
        }
        let add = PanelTile(symbol: "plus", caption: nil)
        add.toolTip = String(localized: "Get Extensions", comment: "Tooltip and VoiceOver name of the + button after the extensions in the site panel: opens the Chrome Web Store.")
        add.setAccessibilityLabel(add.toolTip)
        add.onClick = { [weak self] _ in
            self?.controller?.tabManager.newTab(url: ExtensionStore.webStoreURL)
            self?.close()
        }
        addSubview(add)
        extensionTiles.append(add)
        addSubview(extensionsLabel)
        // Over its tile.
        for entry in hoverPins {
            addSubview(entry.pin)
            wireHoverPin(entry.tile, entry.pin, id: entry.id)
        }
        refreshHoverPins()
        extensionsToken = ExtensionCenter.changed.observe { [weak self] in self?.refreshHoverPins() }
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

    // What the rows of This Site say they're set to, and the button that forgets an answer.
    private static let onHere = String(localized: "On for this site", comment: "Under a row's name in the site panel's This Site group, what it's set to: on.")
    private static let offHere = String(localized: "Off for this site", comment: "Under a row's name in the site panel's This Site group, what it's set to: off.")
    private static let allowed = String(localized: "Allowed", comment: "Under a row's name in the site panel's This Site group, what it's set to: the site may use it.")
    private static let blocked = String(localized: "Blocked", comment: "Under a row's name in the site panel's This Site group, what it's set to: the site may not use it.")
    private static let askAgain = String(localized: "Ask Again", comment: "Button on a row in the site panel's This Site group: forgets the answer, so the site asks next time.")

    private func buildRows() {
        rows = []
        if ContentBlocker.isEnabled {
            let blocked = !ContentBlocker.isAllowed(on: url)
            rows.append(.toggle(String(localized: "Ad blocking", comment: "Row in the site panel's This Site group."), on: blocked, status: { $0 ? Self.onHere : Self.offHere }) { [weak self] on in
                guard let self else { return }
                ContentBlocker.setAllowed(!on, on: self.url)
                self.tab.reload()
            })
        }
        // Not in a private window, where extensions don't run (and its site would be kept in the list).
        if #available(macOS 15.4, *), tab.extensionHost?.contexts.isEmpty == false {
            let off = ExtensionStore.extensionsOffSites.contains(site)
            rows.append(.toggle(String(localized: "Extensions", comment: "Row in the site panel's This Site group."), on: !off, status: { $0 ? Self.onHere : Self.offHere }) { [weak self] on in
                guard let self else { return }
                var sites = ExtensionStore.extensionsOffSites
                if on { sites.remove(self.site) } else { sites.insert(self.site) }
                ExtensionStore.extensionsOffSites = sites
                self.tab.reload()
            })
        }
        if let language = tab.foreignLanguage {
            let name = PageTranslator.name(of: language)
            let always = String(localized: "Always translated", comment: "Under a language's name in the site panel's This Site group: pages in it are always translated.")
            let asked = String(localized: "Translated when you ask", comment: "Under a language's name in the site panel's This Site group: pages in it are translated only when asked.")
            rows.append(.toggle(name, status: { $0 ? always : asked }, on: PageTranslator.translatesAlways(language)) { [weak self] on in
                PageTranslator.setTranslatesAlways(on, language)
                if on, self?.tab.isTranslated == false { self?.controller?.translatePage() }
            })
        }
        // Answers are the page's origin's: another port or scheme on the same host has its own.
        if let origin {
            // Calls (Meet, Zoom, Teams) ask for both at once and are kept as one answer; that counts here too, and
            // so do the answers of a call from elsewhere embedded in the page.
            let media = SitePermissions.mediaDecisions(origin: origin)
            if !media.isEmpty {
                let allowed = media.allSatisfy { $0 }
                rows.append(.value(String(localized: "Camera and microphone", comment: "Row in the site panel's This Site group."), allowed ? Self.allowed : Self.blocked, action: Self.askAgain) { [weak self] in
                    SitePermissions.forget(origin: origin)
                    self?.rebuildRows()
                })
            }
            let locations = SitePermissions.locationDecisions(origin: origin)
            if !locations.isEmpty {
                let allowed = locations.allSatisfy { $0 }
                rows.append(.value(String(localized: "Location", comment: "Row in the site panel's This Site group."), allowed ? Self.allowed : Self.blocked, action: Self.askAgain) { [weak self] in
                    SitePermissions.forgetLocation(origin: origin)
                    self?.rebuildRows()
                })
            }
            // Once answered, the answer; asked and not answered (the question went before you got to it), off until
            // you turn it on here.
            let answer = SitePermissions.notifications(origin: origin)
            if !tab.isPrivate, answer != nil || WebNotifications.shared.hasAsked(origin: origin) {
                var decided = answer != nil
                let unanswered = String(localized: "Not allowed yet", comment: "Under Notifications in the site panel's This Site group: the site asked to send notifications, and no one answered yet.")
                rows.append(.toggle(String(localized: "Notifications", comment: "Row in the site panel's This Site group."), on: answer ?? false,
                                    status: { $0 ? Self.allowed : (decided ? Self.blocked : unanswered) }) { on in
                    decided = true
                    SitePermissions.setNotifications(on, origin: origin)
                    if !on { WebNotifications.shared.removeAll(origin: origin) }
                })
            }
            if !tab.isPrivate, SitePermissions.popups(origin: origin) {
                rows.append(.toggle(String(localized: "Pop-ups", comment: "Row in the site panel's This Site group."), on: true, status: { $0 ? Self.allowed : Self.blocked }) { on in
                    SitePermissions.setPopups(on ? true : nil, origin: origin)
                })
            }
        }
        // The page's zoom as it is: in a private window that's its own, which isn't saved for the site.
        let zoom = tab.webView?.pageZoom ?? ZoomLevels.zoom(for: url)
        if abs(zoom - 1) > 0.001 {
            rows.append(.value(String(localized: "Zoom", comment: "Row in the site panel's This Site group."), "\(Int((zoom * 100).rounded()))%",
                                action: String(localized: "Reset", comment: "Button on the Zoom row of the site panel. It sets the page back to 100%.")) { [weak self] in
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
            await WebsiteData.clear(kind, site: site)
            tab.reload()
            if let controller { Toast.show(kind == .cache ? String(localized: "Cache cleared for \(site)", comment: "Toast after one site's cache is cleared. The site is a domain, like example.com.")
                                                       : String(localized: "Cookies cleared for \(site)", comment: "Toast after one site's cookies are cleared. The site is a domain, like example.com."),
                                        symbol: "checkmark.circle", in: controller) }
        }
    }

    // MARK: Layout

    private func layoutContent() { _ = layoutContent(dryRun: false) }

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
        siteName.attributedStringValue = Self.fitted(site, in: textWidth)
        // Its ink, not the text field's inset edge, starts over the lock below, with all of `textWidth` to fit in.
        place(siteName, NSRect(x: textX - Label.inset, y: y, width: textWidth + Label.inset * 2, height: siteName.lineHeight))
        let lockSide: CGFloat = 10
        place(securityIcon, NSRect(x: textX, y: y + siteName.lineHeight + 3, width: lockSide, height: lockSide))
        place(security, NSRect(x: textX + lockSide + 4, y: y + siteName.lineHeight + 1, width: textWidth - lockSide - 4, height: security.lineHeight))
        y += headerHeight + Tokens.Space.x4

        // Actions are named tiles, as many to a row as fit; extensions are icons on the same rhythm below.
        var gap = Tokens.Space.x2
        func grid(_ tiles: [PanelTile], columns: Int, centered: Bool = false, height: ((CGFloat) -> CGFloat)? = nil) {
            let side = floor((inner - gap * CGFloat(columns - 1)) / CGFloat(columns))
            let h = height?(side) ?? side
            let rows = (tiles.count + columns - 1) / columns
            for (i, tile) in tiles.enumerated() {
                let column = i % columns, row = i / columns
                // A shorter last row sits in the middle under the full ones (three over two), not hanging to the left.
                let inRow = row == rows - 1 ? tiles.count - row * columns : columns
                let shift = centered ? CGFloat(columns - inRow) * (side + gap) / 2 : 0
                place(tile, NSRect(x: pad + shift + CGFloat(column) * (side + gap), y: y + CGFloat(row) * (h + gap), width: side, height: h))
            }
            y += CGFloat((tiles.count + columns - 1) / columns) * (h + gap) - gap
        }
        let columns = inner >= 260 ? 6 : inner >= 200 ? 5 : 4
        if !actionTiles.isEmpty {
            // One row, like the markings along a device's edge: every action side by side. In a narrow panel,
            // where a name wouldn't show whole, they share two even rows instead.
            let spacing = gap
            gap = 0
            let widest = actionTiles.map(\.captionWidth).max() ?? 0
            let fit = max(1, Int(inner / max(widest, 1)))
            let rows = fit >= actionTiles.count ? 1 : (actionTiles.count + fit - 1) / fit
            grid(actionTiles, columns: (actionTiles.count + rows - 1) / rows, centered: true) { _ in PanelTile.captionedHeight }
            gap = spacing
            y += Tokens.Space.x5
        }
        if !extensionTiles.isEmpty {
            place(extensionsLabel, NSRect(x: pad - Label.inset, y: y, width: inner + Label.inset * 2, height: extensionsLabel.lineHeight))
            y += extensionsLabel.lineHeight + Tokens.Space.x2
            grid(extensionTiles, columns: columns)
            y += Tokens.Space.x5
        }

        // This site's own settings.
        if !rows.isEmpty {
            place(siteLabel, NSRect(x: pad - Label.inset, y: y, width: inner + Label.inset * 2, height: siteLabel.lineHeight))
            y += siteLabel.lineHeight + Tokens.Space.x2
            let h = group.height
            place(group, NSRect(x: pad, y: y, width: inner, height: h))
            y += h - group.bottomSlack
        } else {
            y -= Tokens.Space.x5
        }
        if !dryRun {
            for entry in hoverPins { entry.pin.frame = Self.pinFrame(on: entry.tile.frame, left: !entry.tile.badge.isEmpty) }
        }
        return y + pad
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
    /// The room left under the last row's words inside its row: the panel's bottom margin counts from the words,
    /// as its top does, so this much less is added there.
    var bottomSlack: CGFloat { rows.last.map { (PanelRow.height - $0.contentHeight) / 2 } ?? 0 }

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
